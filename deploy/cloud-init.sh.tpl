#!/usr/bin/env bash
# cloud-init bootstrap script — rendered by Terraform templatefile()
# Runs once on first boot via cloud-init user-data.
set -euo pipefail

apt-get update -qq
apt-get install -y -qq git curl

# Clone or update the repository
if [[ -d "${install_dir}/.git" ]]; then
  git -C "${install_dir}" pull --quiet origin "${repo_branch}"
else
  git clone --branch "${repo_branch}" --depth 1 "${repo_url}" "${install_dir}"
fi

cd "${install_dir}"

# Create config files from examples if absent
[[ -f ".env" ]]           || cp ".env.example" ".env"
[[ -f "vpn/app/users.yaml" ]] || cp "vpn/app/users.yaml.example" "vpn/app/users.yaml"

# Run the full VPS setup (non-interactive)
bash vpn/init/setup-vps.sh
