![CI](https://github.com/dx-zone/certbot-repo-deployment-bootstrap/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)
![Release](https://img.shields.io/github/v/release/dx-zone/certbot-repo-deployment-bootstrap)

# 🏗️ Certbot Repo Deployment Bootstrapper

### *Enterprise-Grade Automation for PKI & Repository Management*

This tool is a high-reliability bootstrap script designed to initialize, manage, and execute the **Certbot Repository Deployment** Ansible role.

It provisions a controlled Python virtual environment using `uv`, enforces root execution for system-level operations, implements execution locking to prevent race conditions, and maintains structured logging for auditability.

------

## 🌟 Key Features

- ⚡ **UV Integration** — Uses [Astral's UV](https://github.com/astral-sh/uv) for fast, pinned Python dependency management.
- 🔒 **Execution Locking** — Prevents concurrent deployments via `/run/lock/certbot-deploy.lock`.
- 📄 **Persistent Logging** — Mirrors output to `/var/log/ansible-deploy/`.
- 📌 **Version Pinning** — Pinned to **Ansible-core 2.16.3** and **community.docker 3.6.0**.
- 🏗️ **Automated Environment Bootstrap** — Clones repository, provisions virtualenv, installs collections, and generates Ansible configuration.
- 🛡️ **Controlled Ownership Model** — Operates as root but assigns repository and environment ownership to the invoking user (`SUDO_USER`).

------

## 🚀 Quick Start

### 1️⃣ Requirements

- Linux (Ubuntu / RHEL / Debian compatible)
- `sudo` access
- `git`, `curl`, and `python3` installed
- Internet access for repository cloning and dependency installation

------

### 2️⃣ Installation & Initialization

Download the script to your server:

```
chmod +x certbot-repo-deployment-bootstrap.sh
sudo ./certbot-repo-deployment-bootstrap.sh init
```

The `init` command will:

- Clone or update the deployment repository
- Install `uv` (if missing)
- Create a Python virtual environment
- Install pinned dependencies
- Install required Ansible Galaxy collections
- Generate `ansible.cfg`, inventory, and `deploy.yml`

------

### 3️⃣ Deployment

```
sudo ./certbot-repo-deployment-bootstrap.sh deploy
```

This runs the generated `deploy.yml` playbook with:

- `--diff`
- `--flush-cache`
- `-vv` verbosity

------

## 🛠️ Command Reference

| Command  | Action                                                       |
| -------- | ------------------------------------------------------------ |
| `init`   | Prepares environment, clones repo, installs Python & Ansible dependencies |
| `deploy` | Executes `deploy.yml` with verbose diff output               |
| `check`  | Executes `deploy.yml` in Ansible check mode (no changes applied) |
| `clean`  | Removes `/opt/certbot-repo-deployment`                       |

------

## 📂 Project Structure

After running `init`, the deployment directory will look like:

```
/opt/certbot-repo-deployment/
├── .venv/               # Managed Python virtual environment
├── roles/               # Ansible roles path
├── collections/         # Galaxy collections
├── inventory/           # Target host definitions
├── ansible.cfg          # Hardened Ansible configuration
└── deploy.yml           # Primary deployment playbook
```

------

## 📜 Logging & Troubleshooting

### Logs

Deployment logs are written to:

```
/var/log/ansible-deploy/deploy_YYYYMMDD.log
```

If not executed as root, logs will only display on stdout.

------

### Locking

If a deployment is already running, you may see:

```
Deployment already in progress (Lock found: /run/lock/certbot-deploy.lock).
```

If a previous execution was interrupted:

```
sudo rm /run/lock/certbot-deploy.lock
```

------

## 🌐 Remote Inventory Configuration

By default, the inventory targets `localhost`.

To deploy to remote hosts, edit:

```
/opt/certbot-repo-deployment/inventory/hosts.ini
```

Example:

```
[certbot_hosts]
repo-server-01 ansible_host=10.0.5.20
repo-server-02 ansible_host=10.0.5.21

[certbot_hosts:vars]
ansible_user=sysadmin
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

You may also modify `deploy.yml` if your role requires additional variables.

------

## 🔄 Updating the Environment

To pull repository updates and ensure the virtual environment matches the pinned versions:

```
sudo ./certbot-repo-deployment-bootstrap.sh init
```

The script will sync the repository and reinstall pinned dependencies as needed.

------

## 🛡️ Security Model

- Script must be executed with `sudo`.
- Root privileges are required for:
  - Writing to `/opt`
  - Writing to `/var/log`
  - Creating lock files in `/run/lock`
- Repository and virtual environment ownership is assigned to the invoking user (`SUDO_USER`) after initialization.

This design ensures:

- Controlled system-level operations
- Predictable file ownership
- Reduced risk of permission conflicts

------

## 📝 Operational Note

Before reporting issues:

1. Review logs in `/var/log/ansible-deploy/`
2. Confirm lock file state
3. Re-run `init` to ensure environment consistency

------

# 
