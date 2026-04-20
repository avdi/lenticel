#!/usr/bin/env bash
# Install frpc + lenticel wrapper, and write ~/.config/lenticel/frpc.toml.
#
# LENTICEL_TOKEN and LENTICEL_SERVER must be resolved by the caller.
# This script does not attempt to read from any secret store.
#
# Required env vars:
#   LENTICEL_TOKEN        Auth token for the frps server
#   LENTICEL_SERVER       Hostname of the frps server (e.g. tunnel.example.com)
#
# Tunnel configuration (optional env vars):
#   LENTICEL_SUBDOMAIN    Subdomain to expose (default: myproject)
#   LENTICEL_PORT         Local port to tunnel (default: 3000)
#
# Multi-port project config (optional env vars):
#   LENTICEL_NAME      Project/subdomain name (also used by lenticel wrapper)
#   LENTICEL_PORTS        Space-separated "port[:label]" (e.g. "3000 3036:vite")
#   LENTICEL_ENV          Semicolon-separated KEY=VALUE with {label} placeholders
set -euo pipefail

FRPC_VERSION=0.61.0
FRPC_BIN="$HOME/.local/bin/frpc"
LENTICEL_BIN="$HOME/.local/bin/lenticel"
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
fi

LENTICEL_REPO="${LENTICEL_REPO:-avdi/lenticel}"
LENTICEL_BRANCH="${LENTICEL_BRANCH:-main}"
_LENTICEL_RAW="https://raw.githubusercontent.com/${LENTICEL_REPO}/${LENTICEL_BRANCH}/client"

_local_or_fetch() {
  local filename="$1" dest="$2"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${filename}" ]]; then
    cp "${SCRIPT_DIR}/${filename}" "$dest"
  else
    curl -fsSL "${_LENTICEL_RAW}/${filename}" -o "$dest"
  fi
}

LENTICEL_DIR="$HOME/.config/lenticel"
BASE_CONFIG="$LENTICEL_DIR/frpc.toml"
INSTALL_FRPC_COPY="$LENTICEL_DIR/install-frpc.sh"

# ---- frpc install ----
if [[ ! -x "$FRPC_BIN" ]]; then
  echo "Installing frpc ${FRPC_VERSION}..."
  mkdir -p "$HOME/.local/bin"
  curl -sL "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_amd64.tar.gz" \
    | tar -xz --strip-components=1 -C "$HOME/.local/bin" \
      "frp_${FRPC_VERSION}_linux_amd64/frpc"
  chmod +x "$FRPC_BIN"
  echo "frpc installed at $FRPC_BIN"
else
  echo "frpc already at $FRPC_BIN ($(frpc --version 2>/dev/null || true))"
fi

# ---- lenticel wrapper ----
mkdir -p "$HOME/.local/bin"
_local_or_fetch lenticel "$LENTICEL_BIN"
chmod +x "$LENTICEL_BIN"
echo "lenticel wrapper installed at $LENTICEL_BIN"

# ---- shell-setup ----
mkdir -p "$LENTICEL_DIR"
_local_or_fetch shell-setup.sh "$LENTICEL_DIR/shell-setup.sh"
echo "shell-setup.sh installed at ~/.config/lenticel/shell-setup.sh"

# ---- install-frpc copy ----
_local_or_fetch install-frpc.sh "$INSTALL_FRPC_COPY"
chmod +x "$INSTALL_FRPC_COPY"
echo "install-frpc.sh installed at ~/.config/lenticel/install-frpc.sh"

if [[ -z "${LENTICEL_TOKEN:-}" ]]; then
  echo ""
  echo "⚠️  LENTICEL_TOKEN not set; lenticel auth is not configured yet."
  echo "   Set LENTICEL_TOKEN before running this script to configure auth."
  echo "   To enable lenticel later, run:"
  echo "     LENTICEL_TOKEN=your_token_here $INSTALL_FRPC_COPY"
  if [[ -f "$BASE_CONFIG" ]]; then
    echo "   Leaving existing ~/.config/lenticel/frpc.toml in place."
  else
    cat > "$BASE_CONFIG" <<EOF
# lenticel is not configured yet: LENTICEL_TOKEN was unavailable.
#
# To configure it later, run:
#
#   LENTICEL_TOKEN=your_token_here $INSTALL_FRPC_COPY
#
# Or rerun the same command later with LENTICEL_TOKEN already present
# in the environment. Once configured, this file will be replaced with
# the auth-bearing frpc.toml used by lenticel.
EOF
    echo "   Wrote ~/.config/lenticel/frpc.toml stub with recovery instructions."
  fi
fi

# ---- base frpc config (auth token only — proxies generated at runtime) ----
if [[ -n "${LENTICEL_TOKEN:-}" ]]; then
  if [[ -z "${LENTICEL_SERVER:-}" ]]; then
    echo "ERROR: LENTICEL_SERVER is not set. Set it to the hostname of your frps server."
    exit 1
  fi
  mkdir -p "$LENTICEL_DIR"
  cat > "$BASE_CONFIG" <<EOF
serverAddr = "${LENTICEL_SERVER}"
serverPort = 7000

auth.method = "token"
auth.token = "${LENTICEL_TOKEN}"

# Keep retrying if frps is temporarily unreachable or another instance
# is holding the same subdomain. frpc will claim it once it's free.
loginFailExit = false
transport.heartbeatInterval = 10

# Legacy single-port proxy (used by lenticel <project> <port> fallback)
[[proxies]]
name = "${LENTICEL_SUBDOMAIN:-myproject}"
type = "http"
localPort = ${LENTICEL_PORT:-3000}
subdomain = "${LENTICEL_SUBDOMAIN:-myproject}"
requestHeaders.set.X-Forwarded-Proto = "https"
EOF

  echo "Base frpc config written to ~/.config/lenticel/frpc.toml"
fi

# ---- project config from env vars ----
if [[ -n "${LENTICEL_NAME:-}" && -n "${LENTICEL_PORTS:-}" ]]; then
  mkdir -p "$HOME/.config/lenticel/projects"
  PROJECT_FILE="$HOME/.config/lenticel/projects/${LENTICEL_NAME}.toml"

  {
    echo "subdomain = \"${LENTICEL_NAME}\""
    echo ""
    for spec in $LENTICEL_PORTS; do
      port="${spec%%:*}"
      label="${spec#*:}"
      [[ "$label" == "$spec" ]] && label=""
      echo "[[ports]]"
      echo "port = ${port}"
      [[ -n "$label" ]] && echo "label = \"${label}\""
      echo ""
    done

    if [[ -n "${LENTICEL_ENV:-}" ]]; then
      echo "[env]"
      _OLD_IFS="${IFS:-}"
      IFS=';'
      for entry in $LENTICEL_ENV; do
        # trim whitespace
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" ]] && continue
        key="${entry%%=*}"
        val="${entry#*=}"
        echo "${key} = \"${val}\""
      done
      IFS="$_OLD_IFS"
    fi
  } > "$PROJECT_FILE"

  echo "Project config written to $PROJECT_FILE"
  echo "  Run: lenticel ${LENTICEL_NAME} -- <command>"
  echo "   or: lenticel ${LENTICEL_NAME}              (tunnel only)"
else
  echo ""
  echo "Next: make sure ~/.local/bin is in your PATH, then:"
  echo "  lenticel <project> serve    # multi-port with project config"
  echo "  lenticel <project> <port>   # single-port legacy mode"
  echo "  lenticel <project> edit     # create/edit project config"
fi
