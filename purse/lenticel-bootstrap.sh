#!/usr/bin/env bash
# Purse-side bootstrapper for lenticel.
# Resolves LENTICEL_TOKEN from available secret stores, then invokes
# the lenticel installer. This script is the purse-specific glue —
# it knows about Zoho Vault. The lenticel installer itself only speaks
# plain env vars.
#
# Set these in your environment or Codespace secrets:
#   LENTICEL_SERVER  — hostname of the frps server
#   ZV_SECRET_ID     — Zoho Vault secret ID for LENTICEL_TOKEN (optional)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- token resolution (purse-specific) ----
ZV_SECRET_ID="${ZV_SECRET_ID:-}"

_zv_get_token() {
  [[ -n "$ZV_SECRET_ID" ]] || return 1
  command -v zv &>/dev/null || return 1
  command -v jq &>/dev/null || return 1
  command -v timeout &>/dev/null || return 1
  local out
  out=$(timeout 5s zv get -id "$ZV_SECRET_ID" --not-safe --output json </dev/null 2>/dev/null) || return 1
  jq -re '.secret.secretData[] | select(.id == "password") | .value' <<< "$out" 2>/dev/null
}

if [[ -z "${LENTICEL_TOKEN:-}" ]]; then
  if [[ "${CODESPACES:-}" == "true" ]]; then
    echo ""
    echo "⚠️  WARNING: Running in a GitHub Codespace but LENTICEL_TOKEN is not set."
    echo "   Fix: github.com → Settings → Codespaces → Secrets → New secret"
    echo "   Name: LENTICEL_TOKEN  |  Value: FRP_AUTH_TOKEN from lenticel server/.env"
    echo "   Then rebuild / reopen this Codespace."
    echo ""
  elif command -v zv &>/dev/null; then
    echo "Trying Zoho Vault (zv) non-interactively..."
    LENTICEL_TOKEN="$(_zv_get_token || true)"
  fi
fi

# ---- delegate to lenticel installer ----
# Currently calls the local copy (lenticel not yet public).
# TODO: when lenticel is public, replace the exec below with:
#   curl -fsSL "https://raw.githubusercontent.com/avdi/lenticel/main/purse/install-frpc.sh" \
#     | LENTICEL_TOKEN="${LENTICEL_TOKEN:-}" \
#       LENTICEL_SERVER="${LENTICEL_SERVER:-}" \
#       bash
exec bash "$SCRIPT_DIR/install-frpc.sh"
