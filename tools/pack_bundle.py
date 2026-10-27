"""Package a stopped server's config directory into an Ansible Vault blob."""

import argparse
import getpass
import hashlib
import io
import json
import re
import tarfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from ansible.parsing.vault import VaultLib, VaultSecret

ACCESS_FILES = {'adminlist.txt', 'bannedlist.txt', 'permittedlist.txt'}


def build_bundle(files, world, source=None):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', world):
        raise ValueError('Invalid world name')
    prefix = f'worlds_local/{world}/'
    for name in files:
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or '\\' in name
                or str(path) != name or name.endswith('.disabled')):
            raise ValueError(f'Unsafe archive path: {name}')
        if not (name.startswith(prefix) or name.startswith('bepinex/') or name in ACCESS_FILES):
            raise ValueError(f'Unexpected file: {name}')

    generations = [n[:-3] for n in files if n.startswith(prefix + '_main.') and n.endswith('.ok')]
    if not generations:
        raise ValueError('No committed Valheim 1.0 save generation found')
    for base in generations:
        if not all(base + suffix in files for suffix in ['.fwl2', '.db2', '.chunks']):
            raise ValueError(f'Incomplete save generation: {base}')
    if not any(n.startswith(prefix) and n.endswith('.chunk') for n in files):
        raise ValueError('World chunk files are missing')

    manifest = {
        'schema': 1,
        'world': world,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'source': source,
        'files': {n: hashlib.sha256(data).hexdigest() for n, data in sorted(files.items())},
    }
    contents = {'config/' + n: data for n, data in files.items()}
    contents['config/.valheim-bundle.json'] = json.dumps(manifest, indent=2).encode() + b'\n'
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        directories = {str(p) for name in contents for p in PurePosixPath(name).parents if str(p) != '.'}
        for name in sorted(directories):
            entry = tarfile.TarInfo(name)
            entry.type = tarfile.DIRTYPE
            entry.mode = 0o700
            archive.addfile(entry)
        for name, data in sorted(contents.items()):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o600
            archive.addfile(entry, io.BytesIO(data))
    return output.getvalue(), manifest


def encrypt(data, password):
    if not password:
        raise ValueError('Vault password is empty')
    secret = VaultSecret(password)
    vault = VaultLib([('default', secret)])
    encrypted = vault.encrypt(data, secret=secret)
    if vault.decrypt(encrypted) != data:
        raise RuntimeError('Vault encryption round-trip failed')
    return encrypted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path, help='Config directory from a stopped server')
    parser.add_argument('--world', default='purgatory')
    parser.add_argument('--password-file', type=Path)
    parser.add_argument('--output', type=Path, default=Path('files/server-bundle.tar.gz.vault'))
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.world):
        parser.error('Invalid world name')
    config = args.config.resolve(strict=True)
    files = {}
    roots = [config / 'worlds_local' / args.world, config / 'bepinex']
    for root in roots:
        if not root.is_dir() or root.is_symlink():
            raise ValueError(f'Expected a real directory: {root}')
        for path in root.rglob('*'):
            if path.is_symlink():
                raise ValueError(f'Symlinks are not allowed: {path}')
            if path.is_file() and not path.name.endswith(('.disabled', '.cfg.default')):
                files[path.relative_to(config).as_posix()] = path.read_bytes()
    for name in ACCESS_FILES:
        path = config / name
        if path.is_symlink():
            raise ValueError(f'Symlinks are not allowed: {path}')
        if path.is_file():
            files[name] = path.read_bytes()
    data, manifest = build_bundle(files, args.world, source='stopped-server-config')
    password = args.password_file.read_bytes().strip() if args.password_file else getpass.getpass('Vault password: ').encode()
    encrypted = encrypt(data, password)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Only ciphertext reaches disk, including the atomic replacement file.
    temporary = args.output.with_suffix(args.output.suffix + '.tmp')
    temporary.write_bytes(encrypted)
    temporary.replace(args.output)
    print(f'Encrypted {len(files)} files for {manifest["world"]}: {args.output}')


if __name__ == '__main__':
    main()
