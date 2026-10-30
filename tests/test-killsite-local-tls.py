#!/usr/bin/env python3
"""WPL-021: isolated killsite local TLS lifecycle regression tests.

Runs a copied killsite against disposable site directories and mocked
make/TLS commands. Never operates on a user's real sites or certificates.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import json

ROOT = Path(__file__).resolve().parents[1]


class KillsiteLocalTLSTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wplab-killsite-tls-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.checkout = self.base / "checkout"
        (self.checkout / "bin").mkdir(parents=True)
        template_dir = self.checkout / "templates" / "wordpress"
        template_dir.mkdir(parents=True)
        (template_dir / "Makefile.tmpl").write_text("destroy:\n\t@true\n")
        shutil.copy2(ROOT / "bin" / "killsite", self.checkout / "bin" / "killsite")
        self.killsite = self.checkout / "bin" / "killsite"
        self.mockbin = self.base / "mockbin"
        self.mockbin.mkdir()
        self.log = self.base / "calls.log"
        self.log.write_text("")
        make = self.mockbin / "make"
        make.write_text(
            '#!/usr/bin/env bash\n'
            'printf "make %s\\n" "$*" >> "$WPLAB_TEST_LOG"\n'
            '[[ "${FAIL_MAKE:-0}" == 0 ]]\n'
        )
        make.chmod(0o755)
        helper = self.checkout / "bin" / "wplab-local-tls"
        helper.write_text(
            '#!/usr/bin/env bash\n'
            'printf "tls %s\\n" "$*" >> "$WPLAB_TEST_LOG"\n'
            '[[ "${FAIL_TLS:-0}" == 0 ]]\n'
        )
        helper.chmod(0o755)
        self.config_dir = self.base / "config"
        self.config_dir.mkdir()
        self.site = "castle"
        self.site_dir = self.base / "sites" / self.site
        self.site_dir.mkdir(parents=True)
        (self.site_dir / "docker-compose.yml").write_text("services: {}\n")
        (self.config_dir / "sites.json").write_text(
            json.dumps({self.site: {"path": str(self.site_dir)}}) + "\n"
        )
        self.set_site_env(enabled="true", mode="subdomain")
        self.set_environment(mode="local")

    def set_site_env(self, *, enabled, mode):
        (self.site_dir / ".env").write_text(
            f"SITE_NAME={self.site}\n"
            f"COMPOSE_PROJECT_NAME={self.site}\n"
            f"MULTISITE_ENABLED={enabled}\n"
            f"MULTISITE_MODE={mode}\n"
        )

    def set_environment(self, *, mode):
        (self.config_dir / "environment.env").write_text(
            f"WPLAB_MODE={mode}\nWPLAB_DOMAIN=wplab.test\n"
        )
        (self.config_dir / "environment.env").chmod(0o600)

    def run_killsite(self, *, confirm=True, fail_tls=False):
        env = os.environ.copy()
        env.update(
            WPLAB_CONFIG_DIR=str(self.config_dir),
            WPLAB_TEST_LOG=str(self.log),
            FAIL_TLS="1" if fail_tls else "0",
            PATH=f"{self.mockbin}{os.pathsep}{env.get('PATH', '')}",
        )
        return subprocess.run(
            ["bash", str(self.killsite), self.site],
            input=f"{self.site if confirm else 'no'}\n",
            capture_output=True, text=True, env=env,
            cwd=self.base, check=False,
        )

    def calls(self):
        return self.log.read_text().splitlines()

    def assert_site_preserved(self):
        self.assertTrue(self.site_dir.is_dir())
        self.assertIn(self.site, json.loads((self.config_dir / "sites.json").read_text()))

    def assert_site_removed(self):
        self.assertFalse(self.site_dir.exists())
        self.assertNotIn(self.site, json.loads((self.config_dir / "sites.json").read_text()))

    def test_local_subdomain_multisite_cleans_tls_after_docker_before_deletion(self):
        result = self.run_killsite()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 2, calls)
        self.assertTrue(calls[0].startswith("make "), calls)
        self.assertEqual(calls[1], "tls cleanup castle wplab.test")
        self.assert_site_removed()

    def test_remote_subdomain_multisite_skips_local_tls(self):
        self.set_environment(mode="remote")
        result = self.run_killsite()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("tls ") for call in self.calls()))
        self.assert_site_removed()

    def test_local_ordinary_site_skips_local_tls(self):
        self.set_site_env(enabled="false", mode="subdirectory")
        result = self.run_killsite()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("tls ") for call in self.calls()))
        self.assert_site_removed()

    def test_tls_cleanup_failure_preserves_site_and_registry(self):
        result = self.run_killsite(fail_tls=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tls cleanup castle wplab.test", self.calls())
        self.assert_site_preserved()

    def test_missing_environment_refuses_deletion(self):
        # A missing WPLab environment must never silently bypass TLS cleanup.
        environment_file = self.config_dir / "environment.env"
        environment_file.unlink()

        result = self.run_killsite()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "WPLab environment configuration missing or unsafe",
            result.stderr,
        )

        # Deletion must stop before Docker or TLS cleanup.
        self.assertEqual(self.calls(), [])
        self.assert_site_preserved()

    def test_cancelled_deletion_never_cleans_tls(self):
        result = self.run_killsite(confirm=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assert_site_preserved()


if __name__ == "__main__":
    unittest.main(verbosity=2)
