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
#  Version:  1.0.0
#===============================================================================
readonly SCRIPT_VERSION="1.0.0"

set -eEuo pipefail

# --- Configuration & Version Pinning ---
REAL_USER=${SUDO_USER:-$USER}
WORKING_DIR="/opt/certbot-repo-deployment"
ROLE_DIR="roles"
TARGET="certbot-repo-deployment"
REPO_URL="https://github.com/dx-zone/certbot-repo-deployment"
LOG_DIR="/var/log/ansible-deploy"
LOG_FILE="${LOG_DIR}/deploy_$(date +%Y%m%d).log"
LOCK_FILE="/run/lock/certbot-deploy.lock"

# Change these to pin your environment
ANSIBLE_CORE_VERSION="2.16.3"
COMMUNITY_DOCKER_VERSION="3.6.0"

# --- Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging & Safety Setup ---
if [[ $EUID -eq 0 ]]; then
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Note: If not root, tee will fail, so we check if log file is writable
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
        log_error "Elevated privileges required."
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

# --- Logic Functions ---

check_dependencies() {
    local deps=("curl" "git" "python3")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            log_error "Required dependency '$dep' is missing. Aborting."
            exit 1
        fi
    done
}

init_role() {
    log_info "Initializing target directory: $WORKING_DIR"
    mkdir -p "$WORKING_DIR/$ROLE_DIR"

    local repo_path="${WORKING_DIR}/${ROLE_DIR}/${TARGET}"
    if [[ ! -d "${repo_path}/.git" ]]; then
        log_info "Cloning role repository..."
        sudo git clone "${REPO_URL}" "${repo_path}"
    else
        log_info "Syncing latest repository changes..."
        sudo git -C "${repo_path}" pull
    fi

    chown -R "$REAL_USER:$REAL_USER" "$WORKING_DIR"
}

setup_python_env() {
    # Install UV if missing
    if ! command -v uv &> /dev/null; then
        log_info "Installing UV package manager..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    # Locate the UV binary dynamically
    local uv_bin
    uv_bin="$(get_uv_bin)"

    # Ensure executable (harmless if already)
    chmod +x "$uv_bin" || true

    cd "$WORKING_DIR"

    log_info "Creating virtual environment for $REAL_USER..."
    sudo "$uv_bin" venv .venv --quiet

    log_info "Pinning Ansible Core to $ANSIBLE_CORE_VERSION..."
    sudo "$uv_bin" pip install \
        "ansible-core==$ANSIBLE_CORE_VERSION" \
        "docker>=7.1.0" \
        "requests" \
        "jmespath" --quiet

    log_info "Fetching Galaxy collections..."
    mkdir -p "$WORKING_DIR/collections"

    sudo "$uv_bin" run ansible-galaxy collection install \
        "community.docker:==$COMMUNITY_DOCKER_VERSION" \
        "community.general" \
        -p "$WORKING_DIR/collections" --force

    chown -R "$REAL_USER:$REAL_USER" "$WORKING_DIR"
}

configure_ansible() {
    log_info "Hardening Ansible configuration..."
    chown -R "$REAL_USER:$REAL_USER" "$WORKING_DIR"

    sudo bash -c "cat << EOF > $WORKING_DIR/ansible.cfg
[defaults]
roles_path = ./roles
collections_path = $WORKING_DIR/collections
inventory = ./inventory/hosts.ini

# Modern way to get YAML output in Ansible Core 2.13+
stdout_callback = default
result_format = yaml

bin_ansible_callbacks = True
nocows = 1
EOF"

    mkdir -p "$WORKING_DIR/inventory"
    sudo bash -c "cat << EOF > $WORKING_DIR/inventory/hosts.ini
[certbot_hosts]
localhost ansible_connection=local
EOF"

    sudo bash -c "cat << EOF > $WORKING_DIR/deploy.yml
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
EOF"
}

get_uv_bin() {
    local uv_bin
    uv_bin="$(command -v uv || true)"
    if [[ -z "${uv_bin}" ]]; then
        uv_bin="/root/.local/bin/uv"
    fi
    echo "${uv_bin}"
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

    local uv_bin
    uv_bin="$(get_uv_bin)"

    log_info "Initiating Production Deployment..."
    sudo "$uv_bin" run ansible-playbook deploy.yml --diff --flush-cache
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

    local uv_bin
    uv_bin="$(get_uv_bin)"

    log_info "Initiating Deployment (check mode)..."
    sudo "$uv_bin" run ansible-playbook deploy.yml --diff --flush-cache -v --check
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
    printf "  Features include safe root execution, structured logging, environment locking,\n"
    printf "  pinned dependencies via UV, and reproducible Ansible runs.\n\n"

    printf "${BOLD}FEATURES:${NC}\n"
    printf "  🔒 Execution locking to prevent concurrent runs\n"
    printf "  📄 Structured logging for traceability\n"
    printf "  📌 Ansible version pinning for consistency\n"
    printf "  🛡️ Privilege handling with controlled root usage\n\n"

    printf "${BOLD}REQUIREMENTS:${NC}\n"
    printf "  - Must be executed with sudo privileges\n"
    printf "  - Internet access to clone repositories and install dependencies\n"
    printf "  - Target hosts defined in inventory (default: localhost)\n\n"

    printf "${BOLD}USAGE:${NC}\n"
    printf "  sudo $0 ${CYAN}{init|deploy|check|clean}${NC}\n\n"

    printf "${BOLD}COMMANDS:${NC}\n"
    printf "  ${GREEN}init${NC}    🚀 ${BOLD}Initialize Environment${NC}\n"
    printf "            Clone role repo, install UV, create virtualenv, pin Ansible version\n\n"

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
        check_dependencies
        init_role
        setup_python_env
        configure_ansible
        log_success "Environment ready at $WORKING_DIR."
        ;;
    check)
        check_root
        acquire_lock
        run_check
        log_success "Deployment check completed."
        ;;
    deploy)
        check_root
        acquire_lock
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
