"""Create an encrypted synthetic fixture, then run the Linux preparation test."""
import os
from pathlib import Path
import subprocess

from tools.pack_bundle import build_bundle, encrypt

root = Path('/tmp/valheim-ansible-smoke')
root.mkdir(mode=0o700)
password = os.urandom(32).hex().encode()
(root / 'key').write_bytes(password)
(root / 'key').chmod(0o600)
files = {f'worlds_local/purgatory/_main.1{s}': b'fixture' for s in ['.ok', '.fwl2', '.db2', '.chunks']}
files['worlds_local/purgatory/1_1.chunk'] = b'initial-progress'
files['bepinex/example.cfg'] = b'fixture'
archive, _ = build_bundle(files, 'purgatory')
(root / 'fixture.vault').write_bytes(encrypt(archive, password))
subprocess.run(['ansible-playbook', '-i', 'localhost,', 'tests/smoke.yml',
                '--vault-password-file', str(root / 'key')], check=True)
