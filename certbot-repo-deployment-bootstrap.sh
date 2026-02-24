#!/usr/bin/env bash
#===============================================================================
#  Certbot Repo Deployment Bootstrapper
#
#  Copyright (c) 2026 Daniel Cruz (dx.zone)
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at:
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#  Repo:     https://github.com/dx-zone/certbot-repo-deployment-bootstrap
#  Author:   Daniel Cruz <dx.zone>
#  Version:  1.0.1
#===============================================================================
readonly SCRIPT_VERSION="1.0.1"

set -eEuo pipefail

# --- Configuration & Version Pinning ---
REAL_USER=${SUDO_USER:-$USER} # Prefer the invoking user for file ownership; UID/GID resolution handles AD/SSSD usernames safely.

# Predictable, root-managed UV path (do NOT rely on per-user installs)
UV_BIN="/usr/local/bin/uv"
UV_INSTALL_URL="https://astral.sh/uv/install.sh"

WORKING_DIR="/opt/certbot-repo-deployment"
ROLE_DIR="roles"
TARGET="certbot-repo-deployment"
REPO_URL="https://github.com/dx-zone/certbot-repo-deployment"

LOG_DIR="/var/log/ansible-deploy"
LOG_FILE="${LOG_DIR}/deploy_$(date +%Y%m%d).log"
LOCK_FILE="/run/lock/certbot-deploy.lock"

# Version pinning
ANSIBLE_CORE_VERSION="2.16.3"          # Preferred: requires Python >= 3.10 (common on Debian/Ubuntu or when Python 3.10+ is installed)
ANSIBLE_CORE_FALLBACK_VERSION="2.15.3" # Fallback: supports Python 3.9 (default on RHEL/AlmaLinux 9 unless Python 3.10+ is added)
COMMUNITY_DOCKER_VERSION="3.6.0"

# --- Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Real user numeric IDs (AD-safe) ---
REAL_UID=""
REAL_GID=""

# --- Logging & Safety Setup ---
if [[ $EUID -eq 0 ]]; then
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE" || true
fi

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -w "$LOG_FILE" ]]; then
        printf "[%s] %b%s%b\n" "$timestamp" "$level" "$*" "$NC" | tee -a "$LOG_FILE"
    else
        printf "[%s] %b%s%b\n" "$timestamp" "$level" "$*" "$NC"
    fi
}

log_info() { log "${CYAN}ℹ️  " "$*"; }
log_success() { log "${GREEN}✅ " "$*"; }
log_warn() { log "${YELLOW}⚠️  " "$*"; }
log_error() { log "${RED}❌ " "$*"; }

# --- Safety Trap ---
cleanup() {
    rm -f "$LOCK_FILE"
}

# --- Root & Environment Verification ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Elevated privileges required. Run with sudo."
        exit 1
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    if [[ -f "$LOCK_FILE" ]]; then
        log_error "Deployment already in progress (Lock found: $LOCK_FILE)."
        exit 1
    fi
    touch "$LOCK_FILE"
    trap cleanup EXIT
}

# --- Helpers ---
resolve_real_user_ids() {
    if ! id "$REAL_USER" >/dev/null 2>&1; then
        log_error "Unable to resolve REAL_USER='$REAL_USER' via 'id'. Check SSSD/LDAP/AD or sudo context."
        exit 1
    fi
    REAL_UID="$(id -u "$REAL_USER")"
    REAL_GID="$(id -g "$REAL_USER")"
}

chown_workdir() {
    # AD-safe: use numeric ownership. Works for user@domain and regular users.
    chown -R "${REAL_UID}:${REAL_GID}" "$WORKING_DIR"
}

check_dependencies() {
    local deps=("curl" "git" "python3")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            log_error "Required dependency '$dep' is missing. Aborting."
            exit 1
        fi
    done
}

ensure_uv() {
    if [[ -x "$UV_BIN" ]]; then
        log_info "UV already present: $UV_BIN"
        return 0
    fi

    log_info "Installing UV to a predictable root-managed path: $UV_BIN"

    # Install using official installer, then move/copy binary to /usr/local/bin
    # The installer typically drops uv into ~/.local/bin for the executing user (root here).
    # We then normalize to UV_BIN for predictability across environments.
    curl -LsSf "$UV_INSTALL_URL" | sh

    local installed_uv="/root/.local/bin/uv"
    if [[ ! -x "$installed_uv" ]]; then
        # Try common fallback location just in case install behavior changes
        installed_uv="$(command -v uv || true)"
    fi

    if [[ -z "${installed_uv}" || ! -x "${installed_uv}" ]]; then
        log_error "UV install completed but uv binary was not found. Expected: /root/.local/bin/uv"
        exit 1
    fi

    install -m 0755 "$installed_uv" "$UV_BIN"
    log_success "UV installed: $UV_BIN"
}

install_ansible_core() {
    local uv_bin="$1"

    log_info "Installing ansible-core (preferred: ${ANSIBLE_CORE_VERSION})..."
    if "$uv_bin" pip install "ansible-core==${ANSIBLE_CORE_VERSION}" --quiet; then
        log_success "Installed ansible-core==${ANSIBLE_CORE_VERSION}"
        return 0
    fi

    log_warn "Failed to install ansible-core==${ANSIBLE_CORE_VERSION}. Falling back to ${ANSIBLE_CORE_FALLBACK_VERSION}..."
    "$uv_bin" pip install "ansible-core==${ANSIBLE_CORE_FALLBACK_VERSION}" --quiet
    log_success "Installed ansible-core==${ANSIBLE_CORE_FALLBACK_VERSION}"
}

init_role() {
    log_info "Initializing target directory: $WORKING_DIR"
    mkdir -p "$WORKING_DIR/$ROLE_DIR"

    local repo_path="${WORKING_DIR}/${ROLE_DIR}/${TARGET}"
    if [[ ! -d "${repo_path}/.git" ]]; then
        log_info "Cloning role repository..."
        git clone "${REPO_URL}" "${repo_path}"
    else
        log_info "Syncing latest repository changes..."
        git -C "${repo_path}" pull
    fi
}

setup_python_env() {
    ensure_uv

    cd "$WORKING_DIR"

    if [[ ! -d ".venv" ]]; then
        log_info "Creating virtual environment (root-managed) under $WORKING_DIR/.venv..."
        "$UV_BIN" venv .venv --quiet
    else
        log_info "Virtual environment already exists: $WORKING_DIR/.venv"
    fi

    install_ansible_core "$UV_BIN"

    log_info "Installing Python dependencies..."
    "$UV_BIN" pip install \
        "docker>=7.1.0" \
        "requests" \
        "jmespath" --quiet

    log_info "Fetching Galaxy collections (local path)..."
    mkdir -p "$WORKING_DIR/collections"

    "$UV_BIN" run ansible-galaxy collection install \
        "community.docker:==${COMMUNITY_DOCKER_VERSION}" \
        "community.general" \
        -p "$WORKING_DIR/collections" --force
}

configure_ansible() {
    log_info "Writing Ansible configuration and inventory..."

    mkdir -p "$WORKING_DIR/inventory"

    cat >"$WORKING_DIR/ansible.cfg" <<EOF
[defaults]
roles_path = ./roles
collections_paths = ./collections
inventory = ./inventory/hosts.ini
EOF

    cat >"$WORKING_DIR/inventory/hosts.ini" <<EOF
[certbot_hosts]
localhost ansible_connection=local
EOF

    cat >"$WORKING_DIR/deploy.yml" <<EOF
- name: Deploy certbot-rpm-mtls-repo via Ansible role
  hosts: certbot_hosts
  become: true
  gather_facts: true
  vars:
    gather_subset:
      - '!all'
      - 'min'
      - 'date_time'
  roles:
    - role: certbot-repo-deployment
EOF
}

run_deploy() {
    if [[ ! -f "$WORKING_DIR/ansible.cfg" ]]; then
        log_error "Ansible configuration not found. Please run 'init' first."
        exit 1
    fi

    cd "$WORKING_DIR"
    if [[ ! -f "deploy.yml" ]]; then
        log_error "Playbook 'deploy.yml' not found in $WORKING_DIR"
        exit 1
    fi

    ensure_uv

    log_info "Initiating Deployment..."
    "$UV_BIN" run ansible-playbook deploy.yml --diff --flush-cache
}

run_check() {
    if [[ ! -f "$WORKING_DIR/ansible.cfg" ]]; then
        log_error "Ansible configuration not found. Please run 'init' first."
        exit 1
    fi

    cd "$WORKING_DIR"
    if [[ ! -f "deploy.yml" ]]; then
        log_error "Playbook 'deploy.yml' not found in $WORKING_DIR"
        exit 1
    fi

    ensure_uv

    log_info "Initiating Deployment (check mode)..."
    "$UV_BIN" run ansible-playbook deploy.yml --diff --flush-cache -v --check
}

# --- Usage ---
usage() {
    clear
    printf "${CYAN}${BOLD}################################################################################${NC}\n"
    printf "${CYAN}${BOLD}# 🏗️  Certbot Repo Deployment Bootstrapper v${SCRIPT_VERSION}${NC}\n"
    printf "${CYAN}${BOLD}################################################################################${NC}\n\n"

    printf "${BOLD}DESCRIPTION:${NC}\n"
    printf "  A bootstrap utility for deploying the ${BOLD}certbot-rpm-mtls-repo${NC} solution via an Ansible role.\n"
    printf "  Runs in standalone mode — no separate Ansible control node required.\n\n"
    printf "  Uses a root-managed, predictable UV binary at ${BOLD}${UV_BIN}${NC}.\n"
    printf "  Provides locking, logging, pinned dependencies, and reproducible Ansible runs.\n\n"

    printf "${BOLD}FEATURES:${NC}\n"
    printf "  🔒 Execution locking to prevent concurrent runs\n"
    printf "  📄 Structured logging for traceability\n"
    printf "  📌 Ansible version pinning with fallback\n"
    printf "  🛡️ Root-managed toolchain for predictability (PCI-friendly)\n\n"

    printf "${BOLD}REQUIREMENTS:${NC}\n"
    printf "  - Must be executed with sudo privileges\n"
    printf "  - Internet access to clone repositories and install dependencies\n"
    printf "  - Target hosts defined in inventory (default: localhost)\n\n"

    printf "${BOLD}USAGE:${NC}\n"
    printf "  sudo $0 ${CYAN}{init|deploy|check|clean}${NC}\n\n"

    printf "${BOLD}COMMANDS:${NC}\n"
    printf "  ${GREEN}init${NC}    🚀 ${BOLD}Initialize Environment${NC}\n"
    printf "            Clone role repo, install UV, create venv, pin Ansible version\n\n"
    printf "  ${GREEN}check${NC}   🔍 ${BOLD}Validate Configuration${NC}\n"
    printf "            Run playbook in check mode (no changes applied)\n\n"
    printf "  ${GREEN}deploy${NC}  📦 ${BOLD}Execute Deployment${NC}\n"
    printf "            Run playbook with diff output\n\n"
    printf "  ${RED}clean${NC}   🧹 ${BOLD}Clean Local Environment${NC}\n"
    printf "            Remove ${WORKING_DIR} and related local artifacts\n\n"

    printf "${BOLD}LOG FILE:${NC}\n"
    printf "  📄 ${LOG_FILE}\n\n"

    exit 1
}

# --- Execution ---
case "${1:-}" in
    init)
        check_root
        acquire_lock
        resolve_real_user_ids
        check_dependencies

        init_role
        setup_python_env
        configure_ansible

        chown_workdir
        log_success "Environment ready at $WORKING_DIR."
        ;;
    check)
        check_root
        acquire_lock
        resolve_real_user_ids

        run_check
        log_success "Deployment check completed."
        ;;
    deploy)
        check_root
        acquire_lock
        resolve_real_user_ids

        run_deploy
        log_success "Deployment completed."
        ;;
    clean)
        check_root
        log_warn "Wiping environment..."
        rm -rf "$WORKING_DIR"
        log_success "Cleanup finished."
        ;;
    *)
        usage
        ;;
esac