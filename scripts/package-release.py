#!/usr/bin/env python3
"""Build and inspect local experimental installers; never install or publish them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)

def output(*args):
    return run(*args, stdout=subprocess.PIPE, text=True).stdout.strip()

def normalized_copy(source, destination):
    run('ditto', source, destination)
    for path in [destination, *destination.rglob('*')]:
        if path.is_symlink():
            raise RuntimeError(f'Unexpected symlink in release payload: {path}')
        path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)

def component(stage, work, name, identifier, version):
    scripts = work / f'{name}-scripts'
    shutil.copytree(ROOT / 'scripts/installer' / name, scripts)
    shutil.copy2(ROOT / 'scripts/installer/common.sh', scripts / 'common.sh')
    for path in scripts.iterdir():
        path.chmod(0o755)
    package = work / f'{name}.pkg'
    args = ['pkgbuild', '--identifier', identifier, '--version', version, '--scripts', scripts, '--ownership', 'recommended']
    if stage:
        manifest = work / f'{name}-components.plist'
        run('pkgbuild', '--analyze', '--root', stage, manifest)
        components = plistlib.loads(manifest.read_bytes())
        for item in components:
            item.update(BundleIsRelocatable=False, BundleIsVersionChecked=False, BundleOverwriteAction='upgrade')
        manifest.write_bytes(plistlib.dumps(components))
        args += ['--root', stage, '--install-location', '/', '--component-plist', manifest]
    else:
        args += ['--nopayload']
    run(*args, package)
    return package

def distribution(work, destination, version, removal=False):
    root = ET.Element('installer-gui-script', {'minSpecVersion': '2'})
    ET.SubElement(root, 'title').text = 'Remove Mixing Desk Audio' if removal else f'Mixing Desk {version} — Experimental Beta'
    ET.SubElement(root, 'options', {'customize': 'never' if removal else 'always', 'hostArchitectures': 'arm64', 'require-scripts': 'true', 'allow-external-scripts': 'false'})
    ET.SubElement(root, 'domains', {'enable_anywhere': 'false', 'enable_currentUserHome': 'false', 'enable_localSystem': 'true'})
    volume = ET.SubElement(root, 'volume-check', {'script': 'true'})
    ET.SubElement(ET.SubElement(volume, 'allowed-os-versions'), 'os-version', {'min': '14.4'})
    ET.SubElement(root, 'welcome', {'file': 'Remove.html' if removal else 'Welcome.html', 'mime-type': 'text/html'})
    ET.SubElement(root, 'conclusion', {'file': 'Removed.html' if removal else 'Installed.html', 'mime-type': 'text/html'})
    # MIT attribution is a notice, not an extra end-user licence agreement.
    ET.SubElement(root, 'readme', {'file': 'LICENSE.txt', 'mime-type': 'text/plain'})
    outline = ET.SubElement(root, 'choices-outline')
    choices = [('remove', 'Remove Mixing Desk Audio', 'Removes only the virtual-audio driver. Restart afterwards. Sessions and presets are preserved.', True)] if removal else [
        ('app', 'Mixing Desk', 'Installs the app in Applications. Quit Mixing Desk before continuing.', True),
        ('driver', 'Mixing Desk Audio (optional)', 'Virtual microphone and recording devices for other apps. Requires administrator access and a Mac restart. Leave unchecked to keep your current driver unchanged.', False)]
    for name, title, description, selected in choices:
        ET.SubElement(outline, 'line', {'choice': name})
        attrs = {'id': name, 'title': title, 'description': description, 'start_selected': str(selected).lower()}
        if name != 'driver':
            attrs['enabled'] = 'false'
        choice = ET.SubElement(root, 'choice', attrs)
        identifier = f'local.mixingdesk.pkg.{name}'
        ET.SubElement(choice, 'pkg-ref', {'id': identifier})
        ref = ET.SubElement(root, 'pkg-ref', {'id': identifier, 'onConclusion': 'RequireRestart' if removal else 'None'})
        if name == 'driver':
            # Installer otherwise includes the restart requirement even when
            # this enabled, optional choice is not selected.
            # onConclusionScript is an expression and overrides onConclusion:
            # https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html
            ref.set('onConclusionScript', "choices['driver'].selected ? 'RequireRestart' : 'None'")
        ref.text = f'{name}.pkg'
        close_ref = ET.SubElement(root, 'pkg-ref', {'id': identifier})
        ET.SubElement(ET.SubElement(close_ref, 'must-close'), 'app', {'id': 'local.mixingdesk.app'})
    path = work / ('Remove.xml' if removal else 'Distribution.xml')
    ET.indent(root)
    ET.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)
    run('productbuild', '--distribution', path, '--resources', work / 'resources', '--package-path', work, destination)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Package the existing, verified build bundles')
    parser.add_argument('--verify-tag', action='store_true', help='Require a clean checkout at the configured release tag')
    args = parser.parse_args()
    version = (ROOT / 'release/version.txt').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-beta\.\d+)?', version):
        raise RuntimeError('Invalid release/version.txt')
    dirty = bool(output('git', 'status', '--porcelain', '--untracked-files=normal'))
    if args.verify_tag:
        if dirty or output('git', 'describe', '--tags', '--exact-match', 'HEAD') != f'v{version}':
            raise RuntimeError('Release packaging requires the clean, exact configured tag')
    if not args.skip_build:
        run('bash', 'scripts/build.sh', env={**os.environ, 'DESK_SIGN_IDENTITY': '-'})
    run('python3', 'scripts/verify-build.py')
    app_info = plistlib.loads((ROOT / 'build/Mixing Desk.app/Contents/Info.plist').read_bytes())
    driver_info = plistlib.loads((ROOT / 'build/MixingDeskAudio.driver/Contents/Info.plist').read_bytes())
    if app_info['CFBundleShortVersionString'] != version.split('-')[0]:
        raise RuntimeError('Release version and app version disagree')
    work = ROOT / 'build/packaging'
    out = ROOT / 'build/release' / version
    shutil.rmtree(work, ignore_errors=True)
    shutil.rmtree(out, ignore_errors=True)
    work.mkdir(parents=True)
    out.mkdir(parents=True)
    app_stage, driver_stage = work / 'app-root', work / 'driver-root'
    normalized_copy(ROOT / 'build/Mixing Desk.app', app_stage / 'Applications/Mixing Desk.app')
    normalized_copy(ROOT / 'build/MixingDeskAudio.driver', driver_stage / 'Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver')
    resources = work / 'resources'
    shutil.copytree(ROOT / 'release/installer', resources)
    shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE.txt')
    component(app_stage, work, 'app', 'local.mixingdesk.pkg.app', app_info['CFBundleShortVersionString'])
    component(driver_stage, work, 'driver', 'local.mixingdesk.pkg.driver', driver_info['CFBundleShortVersionString'])
    component(None, work, 'remove', 'local.mixingdesk.pkg.remove', app_info['CFBundleShortVersionString'])
    distribution(work, out / f'MixingDesk-{version}-arm64.pkg', version)
    distribution(work, out / f'Remove-MixingDesk-Audio-{version}.pkg', version, removal=True)
    metadata = {'release': version, 'commit': output('git', 'rev-parse', 'HEAD'), 'dirty': dirty,
                'architecture': 'arm64', 'minimum_macos': '14.4', 'app_build': app_info['CFBundleVersion'],
                'driver_version': driver_info['CFBundleShortVersionString'], 'driver_build': driver_info['CFBundleVersion'],
                'signing': 'ad-hoc', 'notarized': False}
    (out / 'BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n')
    shutil.copy2(ROOT / 'docs/INSTALL.md', out / 'INSTALL.md')
    (out / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.is_file()))
    run('python3', 'scripts/verify-packages.py', out)
    print(f'Experimental artifacts prepared: {out}\nNot installed or published. Complete the acceptance checklist before publication.')

if __name__ == '__main__':
    main()
