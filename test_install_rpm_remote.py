#!/usr/bin/env python3
"""Unit tests for install_rpm_remote helpers (no live SSH required)."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import install_rpm_remote as mod


class ParseHostsTests(unittest.TestCase):
    def test_comma_separated_hosts(self) -> None:
        targets = mod.parse_hosts("a.example,b.example:2222", None)
        self.assertEqual(
            [(t.hostname, t.port) for t in targets],
            [("a.example", 22), ("b.example", 2222)],
        )

    def test_hosts_file_skips_comments_and_blanks(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("# comment\n\nhost1\nhost2:2222\n# trailing\n")
            path = fh.name
        try:
            targets = mod.parse_hosts(None, path)
            self.assertEqual(
                [(t.hostname, t.port) for t in targets],
                [("host1", 22), ("host2", 2222)],
            )
        finally:
            Path(path).unlink(missing_ok=True)

    def test_deduplicates(self) -> None:
        targets = mod.parse_hosts("a,a,a:22", None)
        self.assertEqual(len(targets), 1)

    def test_requires_hosts(self) -> None:
        with self.assertRaises(ValueError):
            mod.parse_hosts(None, None)


class BuildInstallCommandTests(unittest.TestCase):
    def test_prefers_dnf_install(self) -> None:
        cmd = mod.build_install_command(
            "/tmp/pkg.rpm", upgrade=False, force=False, sudo=False
        )
        self.assertIn("dnf install -y", cmd)
        self.assertIn("yum install -y", cmd)
        self.assertIn("rpm -ivh", cmd)
        self.assertIn("/tmp/pkg.rpm", cmd)

    def test_upgrade_and_force_and_sudo(self) -> None:
        cmd = mod.build_install_command(
            "/tmp/my pkg.rpm", upgrade=True, force=True, sudo=True
        )
        self.assertTrue(cmd.startswith("sudo -n bash -lc"))
        self.assertIn("dnf upgrade -y --force", cmd)
        self.assertIn("rpm -Uvh --force", cmd)


class DryRunInstallTests(unittest.TestCase):
    def test_dry_run_does_not_connect(self) -> None:
        installer = mod.RemoteRpmInstaller(
            username="root",
            dry_run=True,
        )
        with tempfile.NamedTemporaryFile(suffix=".rpm") as fh:
            local = Path(fh.name)
            with mock.patch.object(installer, "connect") as connect:
                result = installer.install(
                    mod.HostTarget("example.com"), local
                )
        connect.assert_not_called()
        self.assertTrue(result.success)
        self.assertIn("Would upload", result.message)


class CliSmokeTests(unittest.TestCase):
    def test_help_exits_zero(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            mod.main(["--help"])
        self.assertEqual(ctx.exception.code, 0)

    def test_missing_rpm_returns_2(self) -> None:
        code = mod.main(["-f", "/no/such/file.rpm", "-H", "host1", "--dry-run"])
        self.assertEqual(code, 2)

    def test_dry_run_cli_success(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".rpm") as fh:
            code = mod.main(
                ["-f", fh.name, "-H", "host1,host2:2222", "--dry-run", "-u", "root"]
            )
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
