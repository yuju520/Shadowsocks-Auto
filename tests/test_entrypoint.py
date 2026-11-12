#!/usr/bin/env python3
"""Exercise real Bash entry/menu paths without root, network or system services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "Shadowsocks-Auto.sh"


class EntrypointTests(unittest.TestCase):
    def execute(self, args=(), input_text=""):
        with tempfile.TemporaryDirectory() as directory:
            startup = Path(directory) / "startup.bash"
            startup.write_text(r'''
entrypoint_guard() {
    if [[ "$BASH_COMMAND" == 'main "$@"' ]]; then
        local fn
        for fn in main main_menu ss_submenu stls_submenu; do
            declare -F "$fn" >/dev/null || {
                printf 'Function missing at entrypoint: %s\n' "$fn" >&2
                exit 95
            }
        done
        # Keep real dispatch and menus; stub only host-specific checks.
        check_root() { :; }
        check_system() { :; }
        ss_detect_backend() { return 1; }
        clear() { :; }
        trap - DEBUG
    fi
}
trap entrypoint_guard DEBUG
''')
            return subprocess.run(
                ["bash", str(SCRIPT), *args],
                input=input_text, text=True, capture_output=True, timeout=10,
                env={**os.environ, "BASH_ENV": str(startup)},
            )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("command not found", result.stderr)

    def test_default_menu(self):
        result = self.execute(input_text="0\n")
        self.assert_success(result)
        self.assertIn("Shadowsocks/ShadowTLS 管理脚本", result.stdout)

    def test_both_submenus(self):
        result = self.execute(input_text="1\n0\n2\n0\n0\n")
        self.assert_success(result)
        self.assertIn("=== Shadowsocks 服务管理 ===", result.stdout)
        self.assertIn("=== ShadowTLS 服务管理 ===", result.stdout)

    def test_help(self):
        result = self.execute(("--help",))
        self.assert_success(result)
        self.assertIn("用法", result.stdout)


if __name__ == "__main__":
    unittest.main()
