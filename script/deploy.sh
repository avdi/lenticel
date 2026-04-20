#!/usr/bin/env bash
# Deploy server files to the VPS and bring up docker compose.
# Usage: VPS_IP=<ip> ./script/deploy.sh
# Requires: ssh access to root@$VPS_IP, and server/.env present locally.
set -euo pipefail

VPS_IP="${VPS_IP:?Set VPS_IP to your VPS IP}"
VPS_USER="${VPS_USER:-root}"
VPS_DIR="/opt/lenticel"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Deploying to ${VPS_USER}@${VPS_IP}:${VPS_DIR}"

# Ensure target directory exists
ssh "${VPS_USER}@${VPS_IP}" "mkdir -p ${VPS_DIR}"

# Render frps.toml from template (keeps token out of the repo)
if [[ -z "${FRP_AUTH_TOKEN:-}" ]]; then
  # Try sourcing server/.env if the var isn't already in the environment
  [[ -f "${REPO_ROOT}/server/.env" ]] && source "${REPO_ROOT}/server/.env"
fi
: "${FRP_AUTH_TOKEN:?FRP_AUTH_TOKEN not set — add it to server/.env}"
envsubst '${FRP_AUTH_TOKEN} ${LENTICEL_DOMAIN}' < "${REPO_ROOT}/server/frps.toml.tmpl" > "${REPO_ROOT}/server/frps.toml"
echo "==> frps.toml rendered"

# Sync server files (excluding .env — copy that separately)
rsync -avz --exclude='.env' \
  "${REPO_ROOT}/server/" \
  "${VPS_USER}@${VPS_IP}:${VPS_DIR}/"

# Copy .env if it exists locally
if [[ -f "${REPO_ROOT}/server/.env" ]]; then
  scp "${REPO_ROOT}/server/.env" "${VPS_USER}@${VPS_IP}:${VPS_DIR}/.env"
  ssh "${VPS_USER}@${VPS_IP}" "chmod 600 ${VPS_DIR}/.env"
  echo "==> .env deployed (chmod 600)"
else
  echo "WARNING: server/.env not found locally — make sure it exists on the VPS already."
fi

# Pull latest images and rebuild caddy, then restart
ssh "${VPS_USER}@${VPS_IP}" bash <<EOF
  set -euo pipefail
  cd ${VPS_DIR}
  docker compose pull frps
  docker compose build caddy
  docker compose up -d
  echo "==> Stack is up"
  docker compose ps
EOF

# Deploy the control API — runs on the host via systemd
echo "==> Deploying lenticel-ctl service"
ssh "${VPS_USER}@${VPS_IP}" bash <<EOF
  set -euo pipefail

  # Ensure ruby is installed
  if ! command -v ruby &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq ruby >/dev/null
    echo "==> Ruby installed"
  fi

  # Install/update the systemd unit
  cp ${VPS_DIR}/lenticel-ctl.service /etc/systemd/system/lenticel-ctl.service
  systemctl daemon-reload
  systemctl enable lenticel-ctl
  systemctl restart lenticel-ctl
  echo "==> lenticel-ctl service running"
  systemctl status lenticel-ctl --no-pager || true
EOF

echo ""
echo "Done. Watch logs with:"
echo "  ssh ${VPS_USER}@${VPS_IP} 'cd ${VPS_DIR} && docker compose logs -f'"
echo "  ssh ${VPS_USER}@${VPS_IP} 'journalctl -u lenticel-ctl -f'"
