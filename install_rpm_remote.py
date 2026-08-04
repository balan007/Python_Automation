#!/usr/bin/env python3
"""
Install RPM packages on one or more remote servers over SSH.

Copies a local .rpm to each host, then installs it with dnf, yum, or rpm
(whichever is available). Supports password or SSH key authentication,
parallel installs, dry-run, upgrade, and force modes.

Examples:
  python install_rpm_remote.py -f pkg.rpm -H host1,host2 -u root -k ~/.ssh/id_rsa
  python install_rpm_remote.py -f pkg.rpm --hosts-file hosts.txt -u admin --sudo
  python install_rpm_remote.py -f pkg.rpm -H 10.0.0.5 -u root -p 'secret' --upgrade
"""

from __future__ import annotations

import argparse
import getpass
import logging
import os
import posixpath
import shlex
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

try:
    import paramiko
except ImportError:  # pragma: no cover - exercised when dependency missing
    sys.stderr.write(
        "Missing dependency: paramiko\n"
        "Install with:  pip install -r requirements.txt\n"
    )
    sys.exit(1)


LOG = logging.getLogger("install_rpm_remote")
_PRINT_LOCK = threading.Lock()


@dataclass(frozen=True)
class HostTarget:
    """A remote host endpoint."""

    hostname: str
    port: int = 22

    @classmethod
    def parse(cls, value: str) -> "HostTarget":
        value = value.strip()
        if not value or value.startswith("#"):
            raise ValueError("empty host entry")
        if value.count(":") == 1 and not value.startswith("["):
            host, port_s = value.rsplit(":", 1)
            if port_s.isdigit():
                return cls(hostname=host, port=int(port_s))
        return cls(hostname=value)


@dataclass
class InstallResult:
    """Outcome of installing on a single host."""

    host: str
    success: bool
    message: str
    stdout: str = ""
    stderr: str = ""


def configure_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def parse_hosts(hosts: Optional[str], hosts_file: Optional[str]) -> List[HostTarget]:
    entries: List[str] = []
    if hosts:
        entries.extend(part.strip() for part in hosts.split(",") if part.strip())
    if hosts_file:
        path = Path(hosts_file)
        if not path.is_file():
            raise FileNotFoundError(f"Hosts file not found: {hosts_file}")
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(line)

    if not entries:
        raise ValueError("Provide at least one host via -H/--hosts or --hosts-file")

    targets: List[HostTarget] = []
    seen = set()
    for entry in entries:
        target = HostTarget.parse(entry)
        key = (target.hostname, target.port)
        if key in seen:
            continue
        seen.add(key)
        targets.append(target)
    return targets


def build_install_command(
    remote_rpm: str,
    *,
    upgrade: bool,
    force: bool,
    sudo: bool,
) -> str:
    """Build a shell command that prefers dnf, then yum, then rpm."""
    rpm_flags = []
    if upgrade:
        rpm_flags.append("-Uvh")
    else:
        rpm_flags.append("-ivh")
    if force:
        rpm_flags.append("--force")
    rpm_flag_str = " ".join(rpm_flags)

    # Quote the remote path for safe shell use.
    quoted = shlex.quote(remote_rpm)

    # dnf/yum handle deps; fall back to rpm for minimal systems.
    force_flag = " --force" if force else ""
    if upgrade:
        dnf_cmd = f"dnf upgrade -y{force_flag} {quoted}"
        yum_cmd = f"yum update -y{force_flag} {quoted}"
    else:
        dnf_cmd = f"dnf install -y{force_flag} {quoted}"
        yum_cmd = f"yum install -y{force_flag} {quoted}"
    rpm_cmd = f"rpm {rpm_flag_str} {quoted}"

    script = (
        f"if command -v dnf >/dev/null 2>&1; then {dnf_cmd}; "
        f"elif command -v yum >/dev/null 2>&1; then {yum_cmd}; "
        f"elif command -v rpm >/dev/null 2>&1; then {rpm_cmd}; "
        f"else echo 'Neither dnf, yum, nor rpm found' >&2; exit 127; fi"
    )
    if sudo:
        return f"sudo -n bash -lc {shlex.quote(script)}"
    return f"bash -lc {shlex.quote(script)}"


class RemoteRpmInstaller:
    """SSH client that uploads and installs an RPM on a remote host."""

    def __init__(
        self,
        *,
        username: str,
        password: Optional[str] = None,
        key_filename: Optional[str] = None,
        passphrase: Optional[str] = None,
        timeout: int = 30,
        remote_dir: str = "/tmp",
        upgrade: bool = False,
        force: bool = False,
        sudo: bool = False,
        dry_run: bool = False,
        keep_remote: bool = False,
    ) -> None:
        self.username = username
        self.password = password
        self.key_filename = key_filename
        self.passphrase = passphrase
        self.timeout = timeout
        self.remote_dir = remote_dir
        self.upgrade = upgrade
        self.force = force
        self.sudo = sudo
        self.dry_run = dry_run
        self.keep_remote = keep_remote

    def connect(self, target: HostTarget) -> paramiko.SSHClient:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        connect_kwargs = {
            "hostname": target.hostname,
            "port": target.port,
            "username": self.username,
            "timeout": self.timeout,
            "allow_agent": True,
            "look_for_keys": self.key_filename is None and self.password is None,
        }
        if self.password is not None:
            connect_kwargs["password"] = self.password
        if self.key_filename:
            connect_kwargs["key_filename"] = self.key_filename
            if self.passphrase:
                connect_kwargs["passphrase"] = self.passphrase
        LOG.debug(
            "Connecting to %s:%s as %s",
            target.hostname,
            target.port,
            self.username,
        )
        client.connect(**connect_kwargs)
        return client

    def run_command(
        self, client: paramiko.SSHClient, command: str
    ) -> Tuple[int, str, str]:
        LOG.debug("Remote command: %s", command)
        _stdin, stdout, stderr = client.exec_command(command, get_pty=False)
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err

    def install(self, target: HostTarget, local_rpm: Path) -> InstallResult:
        host_label = f"{target.hostname}:{target.port}"
        remote_rpm = posixpath.join(self.remote_dir, local_rpm.name)
        install_cmd = build_install_command(
            remote_rpm,
            upgrade=self.upgrade,
            force=self.force,
            sudo=self.sudo,
        )

        if self.dry_run:
            msg = (
                f"Would upload {local_rpm} -> {host_label}:{remote_rpm} "
                f"and run: {install_cmd}"
            )
            LOG.info("[%s] DRY-RUN: %s", host_label, msg)
            return InstallResult(host=host_label, success=True, message=msg)

        client: Optional[paramiko.SSHClient] = None
        try:
            client = self.connect(target)
            LOG.info("[%s] Uploading %s -> %s", host_label, local_rpm, remote_rpm)
            sftp = client.open_sftp()
            try:
                try:
                    sftp.stat(self.remote_dir)
                except OSError:
                    self.run_command(client, f"mkdir -p {shlex.quote(self.remote_dir)}")
                sftp.put(str(local_rpm), remote_rpm)
            finally:
                sftp.close()

            LOG.info("[%s] Installing package", host_label)
            code, out, err = self.run_command(client, install_cmd)
            if code != 0:
                message = f"Install failed with exit code {code}"
                LOG.error("[%s] %s\n%s%s", host_label, message, out, err)
                return InstallResult(
                    host=host_label,
                    success=False,
                    message=message,
                    stdout=out,
                    stderr=err,
                )

            if not self.keep_remote:
                cleanup = f"rm -f {shlex.quote(remote_rpm)}"
                if self.sudo:
                    cleanup = f"sudo -n rm -f {shlex.quote(remote_rpm)}"
                self.run_command(client, cleanup)

            LOG.info("[%s] Success", host_label)
            return InstallResult(
                host=host_label,
                success=True,
                message="Installed successfully",
                stdout=out,
                stderr=err,
            )
        except Exception as exc:  # noqa: BLE001 - surface any SSH/IO failure
            LOG.error("[%s] %s", host_label, exc)
            return InstallResult(host=host_label, success=False, message=str(exc))
        finally:
            if client is not None:
                client.close()


def install_on_hosts(
    installer: RemoteRpmInstaller,
    targets: Sequence[HostTarget],
    local_rpm: Path,
    workers: int,
) -> List[InstallResult]:
    results: List[InstallResult] = []
    worker_count = max(1, min(workers, len(targets)))

    if worker_count == 1:
        for target in targets:
            results.append(installer.install(target, local_rpm))
        return results

    with ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = {
            pool.submit(installer.install, target, local_rpm): target
            for target in targets
        }
        for future in as_completed(futures):
            results.append(future.result())
    # Preserve input order for the summary.
    order = {(f"{t.hostname}:{t.port}"): i for i, t in enumerate(targets)}
    results.sort(key=lambda r: order.get(r.host, 0))
    return results


def print_summary(results: Iterable[InstallResult]) -> int:
    results = list(results)
    ok = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    with _PRINT_LOCK:
        print()
        print("=" * 60)
        print(f"Summary: {len(ok)} succeeded, {len(failed)} failed "
              f"out of {len(results)} host(s)")
        print("=" * 60)
        for result in results:
            status = "OK" if result.success else "FAIL"
            print(f"  [{status}] {result.host}: {result.message}")
            if not result.success and result.stderr.strip():
                for line in result.stderr.strip().splitlines()[-5:]:
                    print(f"         {line}")
        print()

    return 0 if not failed else 1


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Install an RPM package on remote servers over SSH.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "-f",
        "--file",
        required=True,
        metavar="RPM",
        help="Local path to the .rpm package to install",
    )
    parser.add_argument(
        "-H",
        "--hosts",
        metavar="HOST[,HOST...]",
        help="Comma-separated host list (host or host:port)",
    )
    parser.add_argument(
        "--hosts-file",
        metavar="PATH",
        help="File with one host (or host:port) per line; # comments allowed",
    )
    parser.add_argument(
        "-u",
        "--user",
        default=os.environ.get("USER", "root"),
        help="SSH username (default: current user, or $USER)",
    )
    parser.add_argument(
        "-p",
        "--password",
        nargs="?",
        const="",
        default=None,
        help="SSH password. Pass -p alone to be prompted securely.",
    )
    parser.add_argument(
        "-k",
        "--identity",
        metavar="KEY",
        help="Path to SSH private key",
    )
    parser.add_argument(
        "--passphrase",
        default=None,
        help="Passphrase for the SSH private key",
    )
    parser.add_argument(
        "--remote-dir",
        default="/tmp",
        help="Remote directory for the uploaded RPM (default: /tmp)",
    )
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="Run the install (and cleanup) with passwordless sudo",
    )
    parser.add_argument(
        "--upgrade",
        action="store_true",
        help="Upgrade if the package is already installed",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Pass --force to the package manager (use with care)",
    )
    parser.add_argument(
        "--keep-remote",
        action="store_true",
        help="Do not delete the uploaded RPM after install",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="SSH connection timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "-w",
        "--workers",
        type=int,
        default=4,
        help="Max parallel SSH sessions (default: 4)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions without connecting or installing",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    configure_logging(args.verbose)

    local_rpm = Path(args.file).expanduser().resolve()
    if not local_rpm.is_file():
        LOG.error("RPM file not found: %s", local_rpm)
        return 2
    if local_rpm.suffix.lower() != ".rpm":
        LOG.warning("File does not end with .rpm: %s", local_rpm)

    try:
        targets = parse_hosts(args.hosts, args.hosts_file)
    except (ValueError, FileNotFoundError) as exc:
        LOG.error("%s", exc)
        return 2

    password = args.password
    if password == "":
        password = getpass.getpass(f"SSH password for {args.user}: ")

    if not args.dry_run and password is None and not args.identity:
        LOG.debug("No password or key given; Paramiko will try agent/default keys")

    installer = RemoteRpmInstaller(
        username=args.user,
        password=password,
        key_filename=args.identity,
        passphrase=args.passphrase,
        timeout=args.timeout,
        remote_dir=args.remote_dir.rstrip("/") or "/tmp",
        upgrade=args.upgrade,
        force=args.force,
        sudo=args.sudo,
        dry_run=args.dry_run,
        keep_remote=args.keep_remote,
    )

    LOG.info(
        "Installing %s on %d host(s)%s",
        local_rpm.name,
        len(targets),
        " (dry-run)" if args.dry_run else "",
    )
    results = install_on_hosts(installer, targets, local_rpm, args.workers)
    return print_summary(results)


if __name__ == "__main__":
    sys.exit(main())
