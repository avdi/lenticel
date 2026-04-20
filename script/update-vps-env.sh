#!/usr/bin/env bash
# Update .env on the VPS from a local server/.env file (or interactively).
# Usage: VPS_IP=<your-vps-ip> bash script/update-vps-env.sh
#
# This is the manual way to rotate secrets on the VPS. CI does NOT deploy
# .env — it only needs FRP_AUTH_TOKEN to render frps.toml. If you rotate
# FRP_AUTH_TOKEN or BUNNY_API_KEY, run this script and also update the
# corresponding GitHub Actions secrets.
set -euo pipefail

VPS_IP="${VPS_IP:?Set VPS_IP to your VPS IP}"
VPS_USER="${VPS_USER:-root}"
VPS_DIR="/opt/lenticel"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV="${REPO_ROOT}/server/.env"

if [[ ! -f "$LOCAL_ENV" ]]; then
  echo "ERROR: $LOCAL_ENV not found."
  echo "Create it with FRP_AUTH_TOKEN and BUNNY_API_KEY, then re-run."
  exit 1
fi

echo "==> Deploying .env to ${VPS_USER}@${VPS_IP}:${VPS_DIR}/.env"
scp "$LOCAL_ENV" "${VPS_USER}@${VPS_IP}:${VPS_DIR}/.env"
ssh "${VPS_USER}@${VPS_IP}" "chmod 600 ${VPS_DIR}/.env"
echo "==> .env deployed (chmod 600)"

echo ""
echo "If you rotated FRP_AUTH_TOKEN, you also need to:"
echo "  1. Update the GitHub Actions secret FRP_AUTH_TOKEN"
echo "  2. Restart the docker stack: ssh lenticel 'cd /opt/lenticel && docker compose up -d'"
echo "  3. Re-run dotfiles/install-frpc.sh on any clients"
echo ""
echo "If you rotated BUNNY_API_KEY, you also need to:"
echo "  1. Update the GitHub Actions secret BUNNY_API_KEY (if used in Terraform CI)"
echo "  2. Update terraform/terraform.tfvars"
echo "  3. Restart the docker stack: ssh lenticel 'cd /opt/lenticel && docker compose up -d'"
