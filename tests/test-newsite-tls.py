#!/usr/bin/env python3
"""Read-only regression tests for newsite's embedded Compose TLS renderer.

No Docker, network, credentials, or WPLab installation is needed.
"""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEWSITE = ROOT / "bin" / "newsite"
TEMPLATE = ROOT / "templates" / "wordpress" / "docker-compose.yml.tmpl"


def renderer_source():
    shell = NEWSITE.read_text(encoding="utf-8")
    heredocs = re.finditer(
        r"(?ms)^python3 - \\\n.*? <<'PY'\n(?P<code>.*?)^PY$", shell
    )
    for match in heredocs:
        code = match.group("code")
        if "__WPLAB_TLS_LABELS__" in code:
            return code
    raise AssertionError("newsite TLS-rendering Python heredoc not found")


def render(*, enabled, mode, site="msauto"):
    host = f"{site}.test.vkuberan.in"
    # In Docker Compose, a literal regex $ must be escaped as $$.
    host_rule = f"Host(`{host}`)"
    if enabled == "true" and mode == "subdomain":
        escaped = host.replace(".", r"\.")
        host_rule += f" || HostRegexp(`^.+\\.{escaped}$$`)"
    with tempfile.TemporaryDirectory(prefix="wplab-tls-test-") as tmp:
        output = Path(tmp) / "docker-compose.yml"
        output.write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, "-", str(output), site, host, host_rule, enabled, mode],
            input=renderer_source(),
            text=True,
            capture_output=True,
            check=False,
        )
        if proc.returncode:
            raise AssertionError(f"TLS renderer failed: {proc.stderr}")
        return output.read_text(encoding="utf-8")


class NewsiteTLSRenderingTests(unittest.TestCase):
    def test_ordinary_site_uses_shared_certificate(self):
        output = render(enabled="false", mode="subdirectory")
        self.assertIn('traefik.http.routers.msauto.tls=true', output)
        self.assertNotIn('traefik.http.routers.msauto.tls.certresolver', output)
        self.assertNotIn('traefik.http.routers.msauto.tls.domains[', output)
        self.assertNotIn('HostRegexp(', output)
        self.assertNotIn('__WPLAB_TLS_LABELS__', output)

    def test_subdirectory_multisite_uses_shared_certificate(self):
        output = render(enabled="true", mode="subdirectory")
        self.assertIn('traefik.http.routers.msauto.tls=true', output)
        self.assertNotIn('traefik.http.routers.msauto.tls.certresolver', output)
        self.assertNotIn('traefik.http.routers.msauto.tls.domains[', output)
        self.assertNotIn('HostRegexp(', output)
        self.assertNotIn('__WPLAB_TLS_LABELS__', output)

    def test_subdomain_multisite_has_nested_wildcard(self):
        output = render(enabled="true", mode="subdomain")
        expected = (
            'traefik.http.routers.msauto.tls.certresolver=dnsresolver',
            'traefik.http.routers.msauto.tls.domains[0].main=msauto.test.vkuberan.in',
            'traefik.http.routers.msauto.tls.domains[0].sans=*.msauto.test.vkuberan.in',
        )
        for label in expected:
            with self.subTest(label=label):
                self.assertEqual(output.count(label), 1)
        self.assertIn('HostRegexp(', output)
        self.assertNotIn('__WPLAB_TLS_LABELS__', output)

    def test_disabled_multisite_does_not_request_wildcard(self):
        output = render(enabled="false", mode="subdomain")
        self.assertNotIn('traefik.http.routers.msauto.tls.certresolver', output)
        self.assertNotIn('traefik.http.routers.msauto.tls.domains[', output)

    def test_hyphenated_site_name(self):
        output = render(enabled="true", mode="subdomain", site="woo-test")
        self.assertIn('traefik.http.routers.woo-test.tls.certresolver=dnsresolver', output)
        self.assertIn('*.woo-test.test.vkuberan.in', output)
        self.assertNotIn('__SITE__', output)
        self.assertNotIn('__TRAEFIK_HOST_RULE__', output)

if __name__ == "__main__":
    unittest.main(verbosity=2)
