#!/usr/bin/env python3
"""Check architecture, deployment target, ad-hoc signatures, and licence payloads."""
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
for name, executable, identifier in [('Mixing Desk.app', 'MixingDesk', 'local.mixingdesk.app'), ('MixingDeskAudio.driver', 'MixingDeskAudio', 'local.mixingdesk.driver')]:
    bundle = root / 'build' / name
    binary = bundle / 'Contents/MacOS' / executable
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == identifier
    assert subprocess.check_output(['lipo', '-archs', binary], text=True).strip() == 'arm64'
    commands = subprocess.check_output(['vtool', '-show-build', binary], text=True)
    assert re.search(r'minos\s+14\.4(?:\.0)?\s', commands), commands
    subprocess.run(['codesign', '--verify', '--strict', bundle], check=True)
    signature = subprocess.run(['codesign', '-dvv', bundle], check=True, capture_output=True, text=True).stderr
    assert 'Signature=adhoc' in signature, 'Experimental releases must explicitly use ad-hoc signing'
    assert (bundle / 'Contents/Resources/LICENSE.txt').read_bytes() == (root / 'LICENSE').read_bytes()
    assert not any(p.is_symlink() or p.stat().st_mode & 0o022 for p in bundle.rglob('*')), 'Unsafe payload permissions or symlink'
    if name.endswith('.app'):
        assert info['LSMinimumSystemVersion'] == '14.4'
        assert (bundle / 'Contents/Resources/MixingDesk.icns').is_file()
        assert (bundle / 'Contents/Resources/VST3-LICENSE.txt').read_bytes() == (root / 'Sources/DeskAudio/VST3SDK/pluginterfaces/LICENSE.txt').read_bytes()
    else:
        protocol = (root / 'Sources/DeskAudio/DriverProtocol.h').read_text()
        assert info['CFBundleVersion'] == re.search(r'MD_DRIVER_BUILD\s+(\d+)', protocol)[1]
print('PASS: arm64 bundles, macOS 14.4 minimum, ad-hoc signatures, licence notices, icon, permissions, and driver build consistency')
