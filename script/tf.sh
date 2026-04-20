#!/usr/bin/env bash
# Wrapper around terraform that syncs state to/from the VPS before/after each run.
# Usage: script/tf.sh plan
#        script/tf.sh apply
#        script/tf.sh <any terraform subcommand>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
STATE_LOCAL="$TF_DIR/terraform.tfstate"
STATE_REMOTE="lenticel:/opt/lenticel/terraform.tfstate"

# Pull state from VPS (ok if it doesn't exist yet)
echo "==> Syncing state from VPS..."
scp "$STATE_REMOTE" "$STATE_LOCAL" 2>/dev/null || echo "    (no remote state yet, starting fresh)"

# Run terraform
cd "$TF_DIR"
terraform "$@"
TF_EXIT=$?

# Push state back to VPS (even if terraform exited non-zero — partial applies still update state)
if [[ -f "$STATE_LOCAL" ]]; then
  echo "==> Syncing state back to VPS..."
  scp "$STATE_LOCAL" "$STATE_REMOTE"
fi

exit $TF_EXIT
