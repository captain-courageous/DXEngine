#!/usr/bin/env python3
"""Build an engine-only app and matching source archive; never bundle owned game data."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import tarfile
import zipfile
import hashlib
import os

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path(os.environ.get('DXENGINE_BUILD_DIR', str(root / 'build'))).resolve()
dist = root / 'dist'
dist.mkdir(exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix='deusex-package-', dir=dist)
release = pathlib.Path(staging.name) / 'Deus Ex Mac'
app = release / 'Deus Ex.app'
game_folder = release / 'Put game files here'
game_folder.mkdir(parents=True)
(game_folder / 'READ ME.txt').write_text(
    'Copy the contents of your installed Deus Ex GOTY game into this folder.\n'
    'System, Maps, Textures, Sounds and Music must be directly inside this folder.\n'
    'Then open Deus Ex.app beside this folder. Keep the app and this folder together.\n'
    'No original game files are included.\n')
shutil.copy2(root / 'NativePort/INSTALL.md', release / 'READ ME.txt')
contents = app / 'Contents'
macos = contents / 'MacOS'
resources = contents / 'Resources'
frameworks = contents / 'Frameworks'
for folder in (macos, resources, frameworks):
    folder.mkdir(parents=True, exist_ok=True)

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

engine = macos / 'DXEngine'
shutil.copy2(build / 'DXEngine.app/Contents/MacOS/DXEngine', engine)
shutil.copy2(build / 'DXEngine.pk3', resources)
icon_src = root / 'NativePort/DeusEx.icns'
if icon_src.is_file():
    shutil.copy2(icon_src, resources / 'DeusEx.icns')
for source in (build / 'Thirdparty/openal-soft/libopenal.1.dylib',):
    target = frameworks / source.name
    if target.exists():
        target.chmod(target.stat().st_mode | 0o200)
    shutil.copy2(source, target)
run('install_name_tool', '-id', '@rpath/libopenal.1.dylib', frameworks / 'libopenal.1.dylib')
run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', engine)

info = dict(CFBundleExecutable='DXEngine', CFBundleIdentifier='local.deusex.native',
            CFBundleName='Deus Ex', CFBundleDisplayName='Deus Ex', CFBundlePackageType='APPL',
            CFBundleIconFile='DeusEx',
            CFBundleShortVersionString=os.environ.get('DEUSEX_VERSION', '0.1.0'),
            CFBundleVersion=os.environ.get('DEUSEX_BUILD_NUMBER', '1'),
            LSMinimumSystemVersion=os.environ.get('DEUSEX_MACOS_MIN', '14.0'),
            NSHighResolutionCapable=True, NSSupportsAutomaticGraphicsSwitching=True,
            LSApplicationCategoryType='public.app-category.role-playing-games',
            LSSupportsGameMode=True, GCSupportsGameMode=True, GCSupportsControllerUserInteraction=True)
with (contents / 'Info.plist').open('wb') as output:
    plistlib.dump(info, output)
source_root = root
licenses = resources / 'Licenses'
for source in source_root.rglob('*'):
    if source.is_file() and source.name.lower().startswith(('license', 'copying')) and not any(p in {'build', '.git', 'dist'} for p in source.relative_to(source_root).parts):
        target = licenses / source.relative_to(source_root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
shutil.copy2(root / 'NativePort/INSTALL.md', resources / 'Read Me.txt')
for binary in [*frameworks.iterdir(), engine]:
    run('codesign', '--force', '--sign', '-', binary)
run('codesign', '--force', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
run('plutil', '-lint', contents / 'Info.plist')
# Reject proprietary game data and links before creating a distributable archive.
for file in app.rglob('*'):
    assert not file.is_symlink(), file
    assert file.suffix.lower() not in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.ini'}, file
for binary in [*frameworks.iterdir(), engine]:
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(' (')[0]
        assert dependency.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/', '/usr/lib/')), dependency
archive = dist / 'Deus-Ex-Mac-ARM64.zip'
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', release, archive)
with zipfile.ZipFile(archive) as zipped:
    names = zipped.namelist()
    assert 'Deus Ex Mac/Put game files here/READ ME.txt' in names
    assert not any(pathlib.PurePosixPath(n).suffix.lower() in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.ini'} for n in names)
    assert not any('/Game/' in n for n in names)
# Include the exact modified engine sources, LGPL libraries and build files.
if (source_root / '.git').exists():
    files = subprocess.check_output(['git', '-C', str(source_root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
else:
    # Extracted source releases do not require a Git checkout.
    files = [str(p.relative_to(source_root)) for p in source_root.rglob('*') if p.is_file()
             and not {'build', '.git', '__pycache__'}.intersection(p.relative_to(source_root).parts)]
source_archive = dist / 'Deus-Ex-Mac-Source.tar.gz'
with tarfile.open(source_archive, 'w:gz') as tar:
    for name in sorted(set(files)):
        if not name: continue
        source = source_root / name
        if source.is_file():
            assert source.suffix.lower() not in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.o', '.a', '.dylib'}, source
            tar.add(source, arcname=str(pathlib.Path('Deus-Ex-Mac/.porting/SurrealEngine') / name), recursive=False)
    for name in ('package_launcher.mm', 'game_install.h', 'package_app.py', 'check_install.cpp', 'check_install.py', 'check_input.py', 'check_input.cpp', 'check_video.mm', 'INSTALL.md', 'DeusEx.icns', 'quick-install.sh', 'RELEASE_README.md'):
        src = root / 'NativePort' / name
        if src.exists():
            tar.add(src, arcname='Deus-Ex-Mac/NativePort/' + name)
shutil.copy2(root / 'NativePort/INSTALL.md', dist / 'INSTALL.md')

# Also assemble a release directory containing the engine-only app tarball,
# zip, checksums, license notices, one-line quick-install.sh, and README ready to host on GitHub.
mac_release = dist / 'macDeusEx-release'
mac_release.mkdir(exist_ok=True)
mac_tar = mac_release / 'DeusEx-macos-arm64.tar.gz'
mac_zip = mac_release / 'DeusEx-macos-arm64.zip'
mac_source = mac_release / source_archive.name
run('tar', '-C', app.parent, '--no-mac-metadata', '-czf', mac_tar, app.name)
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, mac_zip)
shutil.copy2(source_archive, mac_source)
(mac_release / 'version.sha').write_text(hashlib.sha256(engine.read_bytes()).hexdigest() + '\n')
for src_name, dst_name in (('NativePort/quick-install.sh', 'quick-install.sh'), ('NativePort/RELEASE_README.md', 'README.md'), ('LICENSE.md', 'LICENSE.md')):
    src = root / src_name
    if src.exists():
        dst = mac_release / dst_name
        shutil.copy2(src, dst)
        if dst_name.endswith('.sh'):
            dst.chmod(0o755)
(mac_release / 'SHA256SUMS.txt').write_text(''.join(
    hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
    for p in (mac_tar, mac_zip, mac_source, mac_release / 'version.sha')
))

(dist / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in (archive, source_archive)))
installed_release = dist / 'Deus Ex Mac'
installed_release.mkdir(exist_ok=True)
# Preserve any game files the user has added when rebuilding locally.
shutil.copytree(game_folder, installed_release / game_folder.name, dirs_exist_ok=True)
shutil.copy2(release / 'READ ME.txt', installed_release / 'READ ME.txt')
installed_app = installed_release / 'Deus Ex.app'
if installed_app.exists(): shutil.rmtree(installed_app)
shutil.move(app, installed_app)
staging.cleanup()
print(archive)
print(source_archive)
print(mac_release)
