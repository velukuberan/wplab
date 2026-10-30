#!/usr/bin/env python3
"""Read-only WPL-021 tests for local Traefik's TLS configuration layout.

Run from the WPLab checkout as: python3 tests/test-local-traefik.py
These tests do not use Docker, mkcert, network access, or modify files.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCAL_STATIC = ROOT / 'traefik' / 'traefik.yml'
LOCAL_COMPOSE = ROOT / 'traefik' / 'docker-compose.yml'
LOCAL_DEFAULT = ROOT / 'traefik' / 'dynamic' / 'default-tls.yml'
REMOTE_ROOT = ROOT / 'traefik' / 'remote'


class LocalTraefikConfigurationTests(unittest.TestCase):
    def test_local_file_provider_watches_configuration_directory(self):
        content = LOCAL_STATIC.read_text(encoding='utf-8')
        self.assertRegex(content, r'(?m)^\s*directory:\s*/etc/traefik/dynamic\s*$')
        self.assertRegex(content, r'(?m)^\s*watch:\s*true\s*$')
        self.assertNotRegex(content, r'(?m)^\s*filename:\s*/etc/traefik/dynamic\.yml\s*$')

    def test_local_compose_mounts_dynamic_directory_read_only(self):
        content = LOCAL_COMPOSE.read_text(encoding='utf-8')
        self.assertIn('./dynamic:/etc/traefik/dynamic:ro', content)
        self.assertNotIn('./dynamic.yml:/etc/traefik/dynamic.yml:ro', content)

    def test_default_shared_certificate_is_still_registered(self):
        self.assertTrue(LOCAL_DEFAULT.is_file(), 'Missing local default-tls.yml')
        content = LOCAL_DEFAULT.read_text(encoding='utf-8')
        self.assertRegex(content, r'(?m)^\s*tls:\s*$')
        self.assertRegex(content, r'(?m)^\s*certificates:\s*$')
        self.assertIn('certFile: /certs/wplab.test.pem', content)
        self.assertIn('keyFile: /certs/wplab.test-key.pem', content)

    def test_shared_certificate_directory_remains_mounted(self):
        content = LOCAL_COMPOSE.read_text(encoding='utf-8')
        self.assertIn('./certs:/certs:ro', content)

    def test_remote_config_is_independent_of_local_dynamic_directory(self):
        self.assertTrue(REMOTE_ROOT.is_dir(), 'Remote Traefik directory missing')
        for path in REMOTE_ROOT.rglob('*.yml*'):
            content = path.read_text(encoding='utf-8')
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertNotIn('/etc/traefik/dynamic/default-tls.yml', content)


if __name__ == '__main__':
    unittest.main(verbosity=2)
