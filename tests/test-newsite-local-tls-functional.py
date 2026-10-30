#!/usr/bin/env python3
"""WPL-021: isolated behavioral tests for newsite local TLS lifecycle.

Runs the actual newsite TLS provisioning and EXIT-trap snippets in a temporary
sandbox using a mocked TLS helper. Does not run Docker, mkcert, or WordPress.
This is a component-level functional test, NOT an end-to-end newsite test.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
NEWSITE = ROOT / 'bin' / 'newsite'


def extract_blocks(source):
    start = source.index('cleanup_on_error() {')
    end = source.index('\ntrap cleanup_on_error EXIT', start)
    cleanup = source[start:end]
    start = source.index('# Local subdomain multisite TLS\n')
    start = source.index('\n', start) + 1
    end = source.index('\n# -----------------------------------------------------------------------------\n# Start site', start)
    provisioning = source[start:end]
    return cleanup, provisioning


class NewsiteLocalTLSFunctionalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cleanup, cls.provisioning = extract_blocks(NEWSITE.read_text(encoding='utf-8'))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wplab-newsite-tls-functional-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.site = self.root / 'testsite'
        self.site.mkdir()
        self.log = self.root / 'helper.log'
        self.helper = self.root / 'fake-tls'
        self.helper.write_text(textwrap.dedent('''\
            #!/usr/bin/env bash
            set -euo pipefail
            printf '%s\\n' "$*" >> "$HELPER_LOG"
            case "$1" in
              provision)
                case "$MOCK_PROVISION" in
                  created) printf 'created %s\\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
                  existing) printf 'existing\\n' ;;
                  failure) echo 'mock provision failure' >&2; exit 8 ;;
                  invalid) printf 'created invalid-token\\n' ;;
                esac
                ;;
              rollback) printf 'rolled-back\\n' ;;
              *) exit 20 ;;
            esac
        '''), encoding='utf-8')
        self.helper.chmod(0o755)

    def execute(self, mode='local', enabled='true', multisite_mode='subdomain', provision='created', failure=True):
        script = '\n'.join([
            'set -euo pipefail',
            'die() { echo "ERROR: $*" >&2; exit 1; }',
            'info() { :; }',
            'CLEANUP_ENABLED=true',
            'LOCAL_TLS_TOKEN=""',
            self.cleanup,
            'trap cleanup_on_error EXIT',
            self.provisioning,
            'exit 17' if failure else 'CLEANUP_ENABLED=false\nexit 0',
        ])
        env = os.environ.copy()
        env.update({
            'WPLAB_MODE': mode,
            'MULTISITE_ENABLED': enabled,
            'MULTISITE_MODE': multisite_mode,
            'WPLAB_LOCAL_TLS': str(self.helper),
            'SITE': 'testsite',
            'SITE_DIR': str(self.site),
            'SITE_HOST': 'testsite.wplab.test',
            'WPLAB_DOMAIN': 'wplab.test',
            'MOCK_PROVISION': provision,
            'HELPER_LOG': str(self.log),
        })
        # No Docker compose file exists in the site, so cleanup cannot invoke Docker.
        return subprocess.run(['bash', '-c', script], cwd=self.root, env=env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text(encoding='utf-8').splitlines() if self.log.exists() else []

    def test_created_then_failure_rolls_back_with_matching_token(self):
        result = self.execute(provision='created', failure=True)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(self.calls(), [
            'provision testsite wplab.test',
            'rollback testsite wplab.test ' + 'a'*64,
        ])

    def test_existing_then_failure_preserves_tls(self):
        result = self.execute(provision='existing', failure=True)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(self.calls(), ['provision testsite wplab.test'])

    def test_provision_failure_does_not_attempt_rollback(self):
        result = self.execute(provision='failure', failure=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ['provision testsite wplab.test'])

    def test_created_then_success_keeps_tls(self):
        result = self.execute(provision='created', failure=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ['provision testsite wplab.test'])

    def test_invalid_created_token_is_not_used_for_rollback(self):
        result = self.execute(provision='invalid', failure=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ['provision testsite wplab.test'])

    def test_remote_mode_does_not_provision_local_tls(self):
        result = self.execute(mode='remote', failure=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

