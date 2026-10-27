from pathlib import Path
import subprocess
import unittest
import xml.etree.ElementTree as ET


class WindowsTemplateTests(unittest.TestCase):
    def test_xml_and_native_argument_quoting(self):
        path = Path(__file__).resolve().parents[1] / '.local/windows-service-test.xml'
        if not path.exists():
            self.skipTest('Run tests/render-windows.yml on the Ansible controller first')
        service = ET.parse(path).getroot()
        root = 'C:\\Valheim Server & Data'
        self.assertEqual(service.findtext('executable'), root + '\\server\\valheim_server.exe')
        self.assertEqual(service.findtext('startmode'), 'Manual')
        self.assertEqual(service.findtext('stoptimeout'), '120 sec')
        expected = ['-nographics', '-batchmode', '-name', 'Purgatory & "Friends"', '-port', '2456',
                    '-world', 'purgatory', '-password', 'test & "quoted"\\end\\', '-savedir', root + '\\config',
                    '-public', '0', '-saveinterval', '600', '-backups', '168', '-backupshort', '3600',
                    '-backuplong', '3600', '-logFile', root + '\\logs\\server.log']
        self.assertEqual(service.findtext('arguments'), subprocess.list2cmdline(expected))
