#!/usr/bin/env python3
"""WPL-021: contract tests for the future local-only TLS provisioner.

These tests are intentionally red until bin/wplab-local-tls is implemented.
They never run Docker, update trust stores, or touch real WPLab certificates.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_NAME = "wplab-local-tls"
SITE = "ms-subdomain"
DOMAIN = "wplab.test"
HOST = f"{SITE}.{DOMAIN}"


class LocalTLSContractTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="wplab-local-tls-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.traefik = self.root / "traefik"
        (self.traefik / "certs").mkdir(parents=True)
        (self.traefik / "dynamic").mkdir(parents=True)
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        self.log = self.root / "mkcert.log"

        source = REPO_ROOT / "bin" / HELPER_NAME
        if source.is_file():
            shutil.copy2(source, self.bin / HELPER_NAME)
        self.helper = self.bin / HELPER_NAME

        # Fake mkcert: verifies requested SANs and writes only test fixtures.
        fake = self.fakebin / "mkcert"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "from pathlib import Path\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['WPLAB_MKCERT_LOG'], 'a') as f:\n"
            "    f.write(repr(args) + '\\n')\n"
            "cert = Path(args[args.index('-cert-file') + 1])\n"
            "key = Path(args[args.index('-key-file') + 1])\n"
            "cert.write_text('FAKE CERT\\n')\n"
            "key.write_text('FAKE KEY\\n')\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)

    def run_helper(self, *args, check=True):
        env = os.environ.copy()
        env["PATH"] = f"{self.fakebin}{os.pathsep}{env.get('PATH', '')}"
        env["WPLAB_MKCERT_LOG"] = str(self.log)
        # Helper is executed from a temporary checkout layout. It must resolve
        # its resources relative to its own location, not the caller's cwd.
        result = subprocess.run(
            ["bash", str(self.helper), *args],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if check and result.returncode:
            self.fail(f"Helper failed ({result.returncode}): {result.stderr}")
        return result

    def cert(self, site=SITE):
        return self.traefik / "certs" / f"{site}.{DOMAIN}.pem"

    def key(self, site=SITE):
        return self.traefik / "certs" / f"{site}.{DOMAIN}-key.pem"

    def config(self, site=SITE):
        return self.traefik / "dynamic" / f"{site}-tls.yml"

    def test_helper_exists(self):
        self.assertTrue(self.helper.is_file(), "Expected bin/wplab-local-tls")

    def test_provision_creates_certificate_and_traefik_registration(self):
        self.run_helper("provision", SITE, DOMAIN)
        self.assertTrue(self.cert().is_file())
        self.assertTrue(self.key().is_file())
        self.assertTrue(self.config().is_file())
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn(HOST, calls)
        self.assertIn(f"*.{HOST}", calls)
        dynamic = self.config().read_text(encoding="utf-8")
        self.assertIn(f"/certs/{HOST}.pem", dynamic)
        self.assertIn(f"/certs/{HOST}-key.pem", dynamic)
        self.assertEqual(self.key().stat().st_mode & 0o777, 0o600)

    def test_repeated_provision_is_idempotent(self):
        self.run_helper("provision", SITE, DOMAIN)
        first_cert = self.cert().read_bytes()
        first_key = self.key().read_bytes()
        first_config = self.config().read_bytes()
        first_calls = self.log.read_text(encoding="utf-8")
        self.run_helper("provision", SITE, DOMAIN)
        self.assertEqual(first_cert, self.cert().read_bytes())
        self.assertEqual(first_key, self.key().read_bytes())
        self.assertEqual(first_config, self.config().read_bytes())
        self.assertEqual(first_calls, self.log.read_text(encoding="utf-8"))

    def test_partial_certificate_pair_is_refused(self):
        self.cert().write_text("PREEXISTING CERT", encoding="utf-8")
        result = self.run_helper("provision", SITE, DOMAIN, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cert().read_text(encoding="utf-8"), "PREEXISTING CERT")
        self.assertFalse(self.key().exists())
        self.assertFalse(self.config().exists())

    def test_two_sites_are_isolated(self):
        other = "ms-other"
        self.run_helper("provision", SITE, DOMAIN)
        self.run_helper("provision", other, DOMAIN)
        for site in (SITE, other):
            self.assertTrue(self.cert(site).is_file())
            self.assertTrue(self.key(site).is_file())
            self.assertTrue(self.config(site).is_file())
        self.assertNotEqual(self.config().read_text(), self.config(other).read_text())

    def test_cleanup_removes_only_owned_site_resources(self):
        other = "ms-other"
        self.run_helper("provision", SITE, DOMAIN)
        self.run_helper("provision", other, DOMAIN)
        self.run_helper("cleanup", SITE, DOMAIN)
        self.assertFalse(self.cert().exists())
        self.assertFalse(self.key().exists())
        self.assertFalse(self.config().exists())
        self.assertTrue(self.cert(other).exists())
        self.assertTrue(self.key(other).exists())
        self.assertTrue(self.config(other).exists())

    def test_invalid_site_name_is_rejected(self):
        for invalid in ("../outside", "BadName", "foo..bar"):
            with self.subTest(site=invalid):
                result = self.run_helper("provision", invalid, DOMAIN, check=False)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.traefik / "certs").iterdir()), [])
        self.assertEqual(list((self.traefik / "dynamic").iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

