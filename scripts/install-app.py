#!/usr/bin/env python3
"""Install Jack without changing its .app folder identity or launching it."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import uuid

PROJECT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def verify(application):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(application)], check=True)
    with (application / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    if info.get('CFBundleIdentifier') != 'dev.jack.desktop' or info.get('CFBundleIconName') != 'AppIcon':
        raise RuntimeError('La compilación no contiene Jack con su icono configurado.')
    for name in ('AppIcon.icns', 'Assets.car'):
        if not (application / 'Contents/Resources' / name).is_file():
            raise RuntimeError('Falta el recurso del icono: ' + name)
    return info


def manifest(application):
    result = {}
    for root, directories, files in os.walk(application / 'Contents', followlinks=False):
        for name in directories + files:
            path = Path(root) / name
            key = str(path.relative_to(application))
            if path.is_symlink():
                result[key] = ('link', os.readlink(path))
            elif path.is_file():
                result[key] = ('file', hashlib.sha256(path.read_bytes()).hexdigest())
            else:
                result[key] = ('directory',)
    return result


def install(source, destination, backups):
    source, destination, backups = map(Path, (source, destination, backups))
    if destination.is_symlink() or source.resolve() == destination.resolve():
        raise RuntimeError('La app de origen y el destino deben ser carpetas distintas, sin enlaces en el destino.')
    info = verify(source)
    expected = manifest(source)
    identifier = uuid.uuid4().hex
    staging = backups / ('.Jack-staging-' + identifier + '.app')
    backup = backups / ('Jack-before-install-' + identifier + '.app')
    backups.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    if destination.stat().st_dev != backups.stat().st_dev:
        raise RuntimeError('La copia anterior debe estar en el mismo volumen que Jack.')
    original_inode = destination.stat().st_ino
    subprocess.run(['ditto', str(source), str(staging)], check=True)
    verify(staging)
    backup.mkdir()
    contents = destination / 'Contents'
    previous = contents.exists()
    if previous:
        os.rename(contents, backup / 'Contents')
    try:
        os.rename(staging / 'Contents', contents)
        verify(destination)
        if manifest(destination) != expected:
            raise RuntimeError('Los archivos instalados no coinciden con la compilación.')
        if destination.stat().st_ino != original_inode:
            raise RuntimeError('Cambió la identidad de la carpeta de la aplicación.')
    except BaseException:
        if contents.exists():
            os.rename(contents, staging / 'FailedContents')
        if previous:
            os.rename(backup / 'Contents', contents)
        raise
    staging.rmdir()
    if not previous:
        backup.rmdir()
    os.utime(destination, None)
    print(f"Instalado: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}). Carpeta de Jack conservada.")
    if previous:
        print('Copia anterior: ' + str(backup))
    return backup if previous else None


def refresh_registration(destination, backup):
    if backup:
        # A newly created backup often has no Launch Services entry (-10814).
        # Removing that optional entry must not prevent registering the installed app.
        subprocess.run([LSREGISTER, '-u', str(backup)], check=False, capture_output=True)
    subprocess.run([LSREGISTER, '-f', str(destination)], check=True)
    subprocess.run(['xcrun', 'swift', str(PROJECT / 'scripts/refresh-dock-entry.swift'), str(destination)], check=True)
    # Refresh only Dock's cached tile. Jack's running process is left untouched.
    subprocess.run(['killall', 'Dock'], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=PROJECT / 'build/Build/Products/Release/Jack.app')
    parser.add_argument('--destination', type=Path, default=Path('/Applications/Jack.app'))
    parser.add_argument('--backups', type=Path, default=PROJECT / 'build/InstalledBackups')
    args = parser.parse_args()
    backup = install(args.source, args.destination, args.backups)
    if args.destination == Path('/Applications/Jack.app'):
        refresh_registration(args.destination, backup)
    print('Jack no se abrió ni se reinició.')


if __name__ == '__main__':
    main()
