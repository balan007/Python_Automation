# Remote RPM Installer

Python CLI that installs an RPM package on one or more remote Linux servers over SSH.

## Features

- Upload a local `.rpm` via SFTP, then install with `dnf`, `yum`, or `rpm`
- Multiple hosts from the CLI or a hosts file
- SSH password or private-key authentication
- Optional passwordless `sudo`
- Parallel installs, dry-run, upgrade, and force modes

## Requirements

- Python 3.8+
- [paramiko](https://www.paramiko.org/)

```bash
pip install -r requirements.txt
```

## Usage

```bash
# Key-based auth
python install_rpm_remote.py -f mypkg-1.0.0.rpm -H host1,host2 -u root -k ~/.ssh/id_rsa

# Password auth (prompted)
python install_rpm_remote.py -f mypkg-1.0.0.rpm -H 10.0.0.5 -u admin -p --sudo

# Hosts file
python install_rpm_remote.py -f mypkg-1.0.0.rpm --hosts-file hosts.example.txt -u root -k ~/.ssh/id_rsa

# Upgrade an existing package
python install_rpm_remote.py -f mypkg-1.1.0.rpm -H host1 -u root -k ~/.ssh/id_rsa --upgrade

# Preview without connecting
python install_rpm_remote.py -f mypkg-1.0.0.rpm -H host1,host2 -u root --dry-run
```

### Hosts file format

```text
# comments and blank lines are ignored
web1.example.com
web2.example.com:2222
10.0.0.10
```

## Options

| Flag | Description |
|------|-------------|
| `-f`, `--file` | Local path to the `.rpm` package |
| `-H`, `--hosts` | Comma-separated `host` or `host:port` list |
| `--hosts-file` | File with one host per line |
| `-u`, `--user` | SSH username |
| `-p`, `--password` | SSH password (`-p` alone prompts) |
| `-k`, `--identity` | SSH private key path |
| `--sudo` | Run install/cleanup with passwordless sudo |
| `--upgrade` | Upgrade if already installed |
| `--force` | Pass `--force` to the package manager |
| `--dry-run` | Print planned actions only |
| `-w`, `--workers` | Max parallel SSH sessions (default: 4) |
| `-v`, `--verbose` | Debug logging |

## Tests

```bash
python -m unittest test_install_rpm_remote.py -v
```
