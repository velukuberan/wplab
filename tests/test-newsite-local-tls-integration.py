#!/usr/bin/env python3
"""WPL-021: read-only source contracts for token-aware local TLS integration.

These tests intentionally do not run newsite, Docker, mkcert, or Traefik.
They complement (but do not replace) functional failure/rollback tests.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEWSITE = ROOT / "bin" / "newsite"


class NewsiteLocalTLSIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = NEWSITE.read_text(encoding="utf-8")

    def test_helper_path_is_resolved_from_checkout(self):
        self.assertIn('WPLAB_LOCAL_TLS="$SCRIPT_DIR/wplab-local-tls"', self.source)

    def test_local_tls_provisioning_is_gated_to_subdomain_multisite(self):
        self.assertRegex(
            self.source,
            r'(?s)if\s+\[\[\s*"\$WPLAB_MODE"\s*==\s*"local".*?'
            r'"\$MULTISITE_ENABLED"\s*==\s*"true".*?'
            r'"\$MULTISITE_MODE"\s*==\s*"subdomain".*?\]\];\s*then.*?'
            r'"\$WPLAB_LOCAL_TLS"\s+provision\s+"\$SITE"\s+"\$WPLAB_DOMAIN"',
        )

    def test_provisioning_runs_before_docker_start(self):
        provision = self.source.find('"$WPLAB_LOCAL_TLS" provision "$SITE" "$WPLAB_DOMAIN"')
        start = self.source.find('info "Starting site..."')
        self.assertGreaterEqual(provision, 0)
        self.assertGreaterEqual(start, 0)
        self.assertLess(provision, start)

    def test_provision_result_is_captured(self):
        self.assertRegex(
            self.source,
            r'(?s)\b[A-Z_]*TLS[A-Z_]*RESULT\s*=\s*\$\(\s*'
            r'"\$WPLAB_LOCAL_TLS"\s+provision\s+"\$SITE"\s+"\$WPLAB_DOMAIN"\s*\)',
            'Capture the helper stdout so ownership is based on its result.',
        )

    def test_created_result_extracts_and_validates_token(self):
        self.assertIn('created ', self.source)
        self.assertRegex(
            self.source,
            r'(?m)^\s*LOCAL_TLS_TOKEN=',
            'Store the helper-issued ownership token for rollback.',
        )
        self.assertRegex(
            self.source,
            r'(?s)\bLOCAL_TLS_TOKEN\b.*?\[\[\s*"\$LOCAL_TLS_TOKEN"\s*=~\s*\^\[0-9a-f\]',
            'Validate the token format instead of accepting arbitrary output.',
        )

    def test_existing_result_does_not_grant_rollback_ownership(self):
        self.assertRegex(
            self.source,
            r'(?m)^\s*existing\)\s*',
            'Handle the existing-result branch distinctly from created.',
        )
        self.assertRegex(
            self.source,
            r'(?s)existing\).*?LOCAL_TLS_TOKEN=(?:""|\x27\x27)(?=\s|\n)',
            'Reused resources must not carry a rollback token.',
        )

    def test_error_cleanup_uses_token_rollback(self):
        match = re.search(r'cleanup_on_error\(\)\s*\{(?P<body>.*?)^\}', self.source, re.S | re.M)
        self.assertIsNotNone(match)
        body = match.group('body')
        self.assertRegex(
            body,
            r'(?s)if\s+\[\[\s*-n\s+"\$LOCAL_TLS_TOKEN"\s*\]\].*?'
            r'"\$WPLAB_LOCAL_TLS"\s+rollback\s+"\$SITE"\s+"\$WPLAB_DOMAIN"\s+"\$LOCAL_TLS_TOKEN"',
            'On failure, only roll back with a helper-issued token.',
        )
        self.assertNotIn('"$WPLAB_LOCAL_TLS" cleanup', body)

    def test_newsite_does_not_infer_ownership_from_tls_paths(self):
        self.assertNotIn('LOCAL_TLS_CREATED', self.source)
        self.assertNotRegex(self.source, r'\btls_cert=|\btls_key=|\btls_registration=')


if __name__ == "__main__":
    unittest.main(verbosity=2)

