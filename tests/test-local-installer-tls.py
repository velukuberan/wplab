#!/usr/bin/env python3
"""Read-only contract tests for WPLab's local installer TLS setup."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'installers' / 'local.sh'
COMMON = ROOT / 'installers' / 'common.sh'
TRAEFIK = ROOT / 'traefik'


class LocalInstallerTLSContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text(encoding='utf-8')

    def test_shared_environment_writer_exists(self):
        self.assertRegex(COMMON.read_text(encoding='utf-8'), r'(?m)^wplab_write_environment\(\)\s*\{')

    def test_local_installer_writes_environment(self):
        self.assertRegex(self.source, r'(?m)^wplab_write_environment\s+local\s+wplab\.test(?:\s|$)')

    def test_environment_is_written_before_starting_traefik(self):
        writer = re.search(r'(?m)^wplab_write_environment\s+local\s+wplab\.test(?:\s|$)', self.source)
        starter = self.source.find("info 'Starting Traefik and Mailpit")
        self.assertIsNotNone(writer, 'Local environment writer missing')
        self.assertGreaterEqual(starter, 0, 'Traefik startup marker missing')
        self.assertLess(writer.start(), starter)

    def test_default_tls_registration_exists(self):
        config = (TRAEFIK / 'dynamic' / 'default-tls.yml').read_text(encoding='utf-8')
        self.assertIn('/certs/wplab.test.pem', config)
        self.assertIn('/certs/wplab.test-key.pem', config)

    def test_installer_checks_default_tls_before_start(self):
        # The installer must refuse startup if the default TLS config is missing.
        # Assert a direct or indirect reference to the required file before startup.
        marker = self.source.find('default-tls.yml')
        starter = self.source.find("info 'Starting Traefik and Mailpit")
        self.assertGreaterEqual(marker, 0, 'Installer does not check default-tls.yml')
        self.assertGreaterEqual(starter, 0)
        self.assertLess(marker, starter)


if __name__ == '__main__':
    unittest.main(verbosity=2)
