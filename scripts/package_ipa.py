#!/usr/bin/env python3
"""Build a separately identified copy of an IPA; never modify the input."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import zipfile


def inject(binary: Path, library: str):
    data = bytearray(binary.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin little-endian 64-bit Mach-O')
    count, command_size = struct.unpack_from('<II', data, 16)
    offset, first_section = 32, len(data)
    libraries = []
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + command_size:
            raise ValueError('Malformed Mach-O load command')
        if command in (0xc, 0x80000018, 0x8000001f):
            start = struct.unpack_from('<I', data, offset + 8)[0]
            libraries.append(data[offset+start:offset+size].split(b'\0')[0].decode())
        if command == 0x19:
            sections = struct.unpack_from('<I', data, offset + 64)[0]
            for i in range(sections):
                section_offset = struct.unpack_from('<I', data, offset + 72 + i*80 + 48)[0]
                if section_offset:
                    first_section = min(first_section, section_offset)
        if command == 0x2c and struct.unpack_from('<I', data, offset + 16)[0] != 0:
            raise ValueError('Encrypted input binary is unsupported')
        offset += size
    if offset != 32 + command_size:
        raise ValueError('Invalid Mach-O command area')
    if library in libraries:
        return
    name = library.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    if offset + size > first_section or any(data[offset:offset+size]):
        raise ValueError('Insufficient zero header padding; refusing to move binary contents')
    command = struct.pack('<IIIIII', 0xc, size, 24, 0, 0, 0) + name
    data[offset:offset+size] = command.ljust(size, b'\0')
    struct.pack_into('<II', data, 16, count+1, command_size+size)
    binary.write_bytes(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('--dylib', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--keychain', type=Path)
    parser.add_argument('--display-name', default='YouTube VOT')
    parser.add_argument('--preserve-url-schemes', action='store_true')
    parser.add_argument('--bundle-id', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    staging = root / 'build' / 'package'
    if args.input.resolve() == args.output.resolve():
        raise ValueError('Output must differ from input')
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    original_hash = hashlib.sha256(args.input.read_bytes()).hexdigest()
    with zipfile.ZipFile(args.input) as z:
        for entry in z.infolist():
            target = staging / entry.filename
            if not target.resolve().is_relative_to(staging.resolve()):
                raise ValueError('Unsafe archive member')
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Symlink member requires explicit support')
            z.extract(entry, staging)
            mode = entry.external_attr >> 16 & 0o777
            if mode:
                target.chmod(mode)
    apps = list((staging / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('Expected exactly one application')
    app = apps[0]
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    original_bundle = info['CFBundleIdentifier']
    if args.bundle_id == original_bundle:
        raise ValueError('Parallel install needs a different bundle ID')
    info.update(CFBundleIdentifier=args.bundle_id, CFBundleDisplayName=args.display_name, CFBundleName=args.display_name)
    # Do not register the original youtube:// scheme and steal links from existing apps.
    if not args.preserve_url_schemes:
        info['CFBundleURLTypes'] = [{'CFBundleURLName':args.bundle_id,'CFBundleURLSchemes':['youtube-vot']}]
    info.pop('CFBundleDocumentTypes', None)
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    for localized in app.glob('*.lproj/InfoPlist.strings'):
        try:
            value = plistlib.loads(localized.read_bytes())
        except Exception:
            # Text strings files also override display names; remove only that override file.
            localized.unlink()
            continue
        value.update(CFBundleDisplayName=args.display_name, CFBundleName=args.display_name)
        localized.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
    # Separate extensions require their own app IDs, profiles and group capabilities.
    for directory in ['PlugIns', 'Watch', '_CodeSignature']:
        shutil.rmtree(app / directory, ignore_errors=True)
    for stale in ['SC_Info', 'embedded.mobileprovision']:
        path = app / stale
        if path.is_dir(): shutil.rmtree(path)
        elif path.exists(): path.unlink()
    binary = app / info['CFBundleExecutable']
    binary.chmod(0o755)
    inject(binary, '@rpath/YouTubeVOT.dylib')
    framework_dir = app / 'Frameworks'
    framework_dir.mkdir(exist_ok=True)
    shutil.copy2(args.dylib, framework_dir / 'YouTubeVOT.dylib')
    shutil.copy2(root / 'LICENSE', app / 'YouTubeVOT-LICENSE.txt')
    shutil.copy2(root / 'THIRD_PARTY_NOTICES.txt', app / 'YouTubeVOT-THIRD-PARTY-NOTICES.txt')
    profile = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(args.profile)], stderr=subprocess.DEVNULL))
    team = profile['TeamIdentifier'][0]
    expected_app_id = team + '.' + args.bundle_id
    allowed_id = profile['Entitlements']['application-identifier']
    if allowed_id != expected_app_id and not (allowed_id.endswith('*') and expected_app_id.startswith(allowed_id[:-1])):
        raise ValueError('Provisioning profile does not allow this bundle identifier')
    shutil.copy2(args.profile, app / 'embedded.mobileprovision')
    entitlements = {'application-identifier':expected_app_id,
        'com.apple.developer.team-identifier':team,
        'get-task-allow':bool(profile['Entitlements'].get('get-task-allow',False)),
        'keychain-access-groups':[expected_app_id]}
    entitlements_path = root / 'build' / 'entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    signer = ['codesign','--force','--sign',args.identity,'--timestamp=none']
    if args.keychain: signer += ['--keychain',str(args.keychain)]
    # Sign nested Mach-O images individually, then frameworks, then the app.
    for path in sorted(app.rglob('*'), key=lambda p:len(p.parts), reverse=True):
        if not path.is_file() or path == binary:
            continue
        with path.open('rb') as f: magic = f.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
            continue
        subprocess.run(signer+[str(path)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    for framework in sorted(app.rglob('*.framework'), key=lambda p:len(p.parts), reverse=True):
        subprocess.run(signer+[str(framework)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    subprocess.run(signer+['--entitlements',str(entitlements_path),str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(args.output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for path in sorted(staging.rglob('*')):
            z.write(path,path.relative_to(staging))
    if hashlib.sha256(args.input.read_bytes()).hexdigest() != original_hash:
        raise RuntimeError('Input archive changed unexpectedly')
    manifest = {'input_sha256':original_hash,'output_sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'bundle_id':args.bundle_id,'display_name':args.display_name,'app_path':str(app),'ipa_path':str(args.output)}
    (root/'build'/'package-manifest.json').write_text(json.dumps(manifest,indent=2))
    print(json.dumps(manifest,indent=2))


if __name__ == '__main__':
    main()
