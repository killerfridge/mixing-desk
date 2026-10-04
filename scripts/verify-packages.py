#!/usr/bin/env python3
"""Inspect installer payloads and evaluate choices without installing anything."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
directory = Path(sys.argv[1]).resolve()
metadata = json.loads((directory / 'BUILD.json').read_text())
version = metadata['release']
for line in (directory / 'SHA256SUMS.txt').read_text().splitlines():
    expected, name = line.split('  ', 1)
    assert Path(name).name == name
    assert hashlib.sha256((directory / name).read_bytes()).hexdigest() == expected, name

for removal in [False, True]:
    filename = f'Remove-MixingDesk-Audio-{version}.pkg' if removal else f'MixingDesk-{version}-arm64.pkg'
    package = directory / filename
    # The CLI query reports static metadata, not the GUI's dynamic choice script.
    restart = subprocess.check_output(['/usr/sbin/installer', '-query', 'RestartAction', '-pkg', package, '-target', '/'], text=True).strip()
    assert restart == ('RequireRestart' if removal else 'None'), f'Unexpected default restart action: {restart}'
    with tempfile.TemporaryDirectory(prefix='mixingdesk-package-') as temporary:
        expanded = Path(temporary) / 'expanded'
        subprocess.run(['pkgutil', '--expand-full', package, expanded], check=True)
        distribution = ET.parse(expanded / 'Distribution').getroot()
        assert distribution.find('options').get('hostArchitectures') == 'arm64'
        assert distribution.find('volume-check/allowed-os-versions/os-version').get('min') == '14.4'
        assert distribution.find('domains').get('enable_anywhere') == 'false'
        assert distribution.findall("pkg-ref/must-close/app[@id='local.mixingdesk.app']")
        choices = {c.get('id'): c for c in distribution.findall('choice')}
        expected_choices = {'remove'} if removal else {'app', 'driver'}
        assert set(choices) == expected_choices
        if not removal:
            assert choices['driver'].get('start_selected') == 'false'
            assert choices['driver'].get('selected') is None, 'Driver choice must remain user-selectable'
            driver_ref = distribution.find("pkg-ref[@id='local.mixingdesk.pkg.driver'][@onConclusionScript]")
            assert driver_ref is not None, 'Optional driver needs a conditional restart requirement'
        for name in expected_choices:
            info = ET.parse(expanded / f'{name}.pkg/PackageInfo').getroot()
            assert info.get('identifier') == f'local.mixingdesk.pkg.{name}'
            assert info.get('install-location', '/') == '/'
            scripts = expanded / f'{name}.pkg/Scripts'
            assert (scripts / 'common.sh').is_file()
            assert (scripts / 'preinstall').is_file()
            common = (scripts / 'common.sh').read_text()
            assert 'Driver Backups' in common and 'pgrep -x MixingDesk' in common
            for script in scripts.iterdir():
                subprocess.run(['bash', '-n', script], check=True)
                text = script.read_text()
                assert not any(command in text for command in ['killall', 'spctl --', 'xattr ', 'launchctl ']), script
        if removal:
            assert not list(expanded.rglob('Payload/Applications'))
            assert (expanded / 'remove.pkg/Scripts/postinstall').is_file()
        else:
            for name, relative in [('app', 'Applications/Mixing Desk.app'), ('driver', 'Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver')]:
                payload = expanded / f'{name}.pkg/Payload'
                bundle = payload / relative
                assert bundle.is_dir(), bundle
                subprocess.run(['codesign', '--verify', '--strict', bundle], check=True)
                expected_license = bundle / 'Contents/Resources/LICENSE.txt'
                assert expected_license.read_bytes() == (root / 'LICENSE').read_bytes()
                for path in payload.rglob('*'):
                    assert not path.is_symlink()
                    assert path.is_dir() or bundle in path.parents, f'Unexpected payload: {path}'
                    assert not path.stat().st_mode & 0o022, f'Writable payload: {path}'
            assert (expanded / 'app.pkg/Payload/Applications/Mixing Desk.app/Contents/Resources/VST3-LICENSE.txt').is_file()
    # Installer evaluates the actual package choices; this command does not install.
    evaluated = plistlib.loads(subprocess.check_output(['/usr/sbin/installer', '-showChoiceChangesXML', '-pkg', package, '-target', '/']))
    selected = {item['choiceIdentifier']: item['attributeSetting'] for item in evaluated if item['choiceAttribute'] == 'selected'}
    assert bool(selected['remove' if removal else 'app'])
    if not removal:
        assert not bool(selected['driver']), 'Optional driver was selected by default'
        with tempfile.TemporaryDirectory(prefix='mixingdesk-choices-') as temporary:
            changes = Path(temporary) / 'choices.plist'
            changes.write_bytes(plistlib.dumps([{'choiceIdentifier': 'driver', 'choiceAttribute': 'selected', 'attributeSetting': 1}]))
            enabled = plistlib.loads(subprocess.check_output(['/usr/sbin/installer', '-showChoicesAfterApplyingChangesXML', changes, '-pkg', package, '-target', '/']))
            selected = {item['choiceIdentifier']: item['attributeSetting'] for item in enabled if item['choiceAttribute'] == 'selected'}
            assert bool(selected['driver']), 'Optional driver cannot be selected'
print('PASS: package payloads/signatures, checksums, licences, scripts, architecture/OS restrictions, and evaluated default/optional choices')
