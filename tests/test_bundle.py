import io
import json
import tarfile
import unittest
from binascii import hexlify, unhexlify

from ansible.parsing.vault import AnsibleVaultError, VaultLib, VaultSecret
from tools.pack_bundle import build_bundle, encrypt


class BundleTests(unittest.TestCase):
    def files(self):
        base = 'worlds_local/purgatory/_main.1'
        return {
            **{base + suffix: b'save' for suffix in ['.ok', '.fwl2', '.db2', '.chunks']},
            'worlds_local/purgatory/1_1.chunk': b'world',
            'bepinex/plugins/example.dll': b'plugin',
            'bepinex/example.cfg': b'configuration',
            'adminlist.txt': b'identity',
        }

    def test_vault_round_trip_preserves_binary_world_and_mods(self):
        files = self.files()
        files['worlds_local/purgatory/1_1.chunk'] = bytes(range(256))
        archive, manifest = build_bundle(files, 'purgatory')
        blob = encrypt(archive, b'a-test-password')
        self.assertTrue(blob.startswith(b'$ANSIBLE_VAULT;1.1;AES256\n'))
        plain = VaultLib([('default', VaultSecret(b'a-test-password'))]).decrypt(blob)
        with tarfile.open(fileobj=io.BytesIO(plain)) as tar:
            for name, data in files.items():
                self.assertEqual(tar.extractfile('config/' + name).read(), data)
            self.assertEqual(json.load(tar.extractfile('config/.valheim-bundle.json')), manifest)

    def test_wrong_key_and_modified_ciphertext_are_rejected(self):
        blob = encrypt(b'binary\0save', b'correct-password')
        with self.assertRaises(AnsibleVaultError):
            VaultLib([('default', VaultSecret(b'wrong-password'))]).decrypt(blob)
        lines = blob.splitlines()
        modified = bytearray(unhexlify(b''.join(lines[1:])))
        modified[-1] = ord('0') if modified[-1] != ord('0') else ord('1')
        with self.assertRaises(AnsibleVaultError):
            VaultLib([('default', VaultSecret(b'correct-password'))]).decrypt(lines[0] + b'\n' + hexlify(modified) + b'\n')

    def test_unsafe_paths_and_disabled_plugins_are_rejected(self):
        for name in ['../escape', '/etc/shadow', 'bepinex/../../escape',
                     'bepinex\\escape', 'bepinex//escape', 'bepinex/bad.dll.disabled',
                     'worlds_local/other-world/file', 'backups/archive.zip']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                build_bundle({**self.files(), name: b'bad'}, 'purgatory')

    def test_incomplete_save_is_rejected(self):
        for suffix in ['.ok', '.fwl2', '.db2', '.chunks']:
            files = self.files()
            del files['worlds_local/purgatory/_main.1' + suffix]
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                build_bundle(files, 'purgatory')


if __name__ == '__main__':
    unittest.main()
