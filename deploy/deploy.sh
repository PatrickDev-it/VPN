#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — Multi-target deployment entry point
#
#  Usage:
#    bash deploy/deploy.sh ubuntu    # bare-metal / VPS (Ansible only)
#    bash deploy/deploy.sh aws       # Terraform infra + Ansible app
#    bash deploy/deploy.sh gcp       # Terraform infra + Ansible app
#    bash deploy/deploy.sh azure     # Terraform infra + Ansible app
#
#  Environment variables:
#    SSH_PUBLIC_KEY  — path to SSH public key (default: ~/.ssh/id_ed25519.pub)
#    TARGET_IP       — skip Terraform, deploy directly to this IP (ubuntu only)
#    TF_APPLY_ARGS   — extra args passed to terraform apply (e.g. -auto-approve)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SSH_KEY_FILE="${SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}"
TF_APPLY_ARGS="${TF_APPLY_ARGS:--auto-approve}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "[ERROR] Required tool not found: $1"
    echo "        Install it and re-run."
    exit 1
  fi
}

banner() {
  echo ""
  echo "======================================================"
  echo "  VPN Platform — Deploy: ${TARGET}"
  echo "======================================================"
  echo ""
}

tf_deploy() {
  local provider="$1"
  local tf_dir="${ROOT_DIR}/infra/terraform/${provider}"

  require_cmd terraform

  echo "[*] Provisioning infrastructure with Terraform (${provider})..."
  cd "${tf_dir}"
  terraform init -upgrade -input=false
  terraform apply ${TF_APPLY_ARGS} \
    -var="ssh_public_key=$(cat "${SSH_KEY_FILE}")"

  TARGET_IP="$(terraform output -raw public_ip 2>/dev/null || true)"
  if [[ -z "${TARGET_IP}" ]]; then
    echo "[ERROR] Could not read public_ip from Terraform output."
    exit 1
  fi
  echo "[OK]   Infrastructure ready: ${TARGET_IP}"
  cd "${ROOT_DIR}"
}

ansible_deploy() {
  local provider="$1"
  local inventory="${ROOT_DIR}/infra/ansible/inventories/${provider}/hosts.ini"
  local playbook="${ROOT_DIR}/infra/ansible/${provider}.yml"

  require_cmd ansible-playbook

  echo "[*] Deploying VPN stack with Ansible (${provider}) → ${TARGET_IP}..."
  ansible-playbook \
    -i "${inventory}" \
    "${playbook}" \
    -e "ansible_host=${TARGET_IP}" \
    --ssh-extra-args="-o StrictHostKeyChecking=accept-new"
  echo "[OK]   Application deployed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
banner

case "${TARGET}" in

  ubuntu)
    require_cmd ansible-playbook
    TARGET_IP="${TARGET_IP:-}"
    if [[ -z "${TARGET_IP}" ]]; then
      echo "[ERROR] Set TARGET_IP to your VPS IP before running."
      echo "        Example: TARGET_IP=1.2.3.4 bash deploy/deploy.sh ubuntu"
      exit 1
    fi
    ansible_deploy ubuntu
    ;;

  aws)
    tf_deploy aws
    ansible_deploy aws
    ;;

  gcp)
    tf_deploy gcp
    ansible_deploy gcp
    ;;

  azure)
    tf_deploy azure
    ansible_deploy azure
    ;;

  *)
    echo "Usage: bash deploy/deploy.sh <target>"
    echo ""
    echo "  Targets:"
    echo "    ubuntu  — bare-metal / existing VPS (requires TARGET_IP)"
    echo "    aws     — provision EC2 + deploy (requires AWS credentials)"
    echo "    gcp     — provision GCE + deploy (requires gcloud auth)"
    echo "    azure   — provision Azure VM + deploy (requires az login)"
    echo ""
    echo "  Environment variables:"
    echo "    TARGET_IP       — skip Terraform, use this IP (ubuntu target)"
    echo "    SSH_PUBLIC_KEY  — path to public key (default: ~/.ssh/id_ed25519.pub)"
    echo "    TF_APPLY_ARGS   — extra terraform apply flags (default: -auto-approve)"
    exit 1
    ;;
esac

echo ""
echo "======================================================"
echo "  Deployment complete!"
echo "  Proxy endpoint: http://${TARGET_IP}:8080"
echo "  SSH:            ssh ubuntu@${TARGET_IP}"
echo "======================================================"
