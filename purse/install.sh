#!/bin/sh
DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ". $DOTFILES_DIR/aliases.sh" >> ~/.profile
echo ". $DOTFILES_DIR/aliases.sh" >> ~/.bashrc

# Zoho Vault CLI (zv)
if ! command -v zv >/dev/null 2>&1; then
  echo "Installing Zoho Vault CLI (zv)..."
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://downloads.zohocdn.com/vault-cli-desktop/linux/zv_cli.zip \
    -o /tmp/zv_cli.zip
  unzip -q -o /tmp/zv_cli.zip zv -d "$HOME/.local/bin"
  chmod +x "$HOME/.local/bin/zv"
  rm -f /tmp/zv_cli.zip
  echo "zv installed at $HOME/.local/bin/zv"
else
  echo "zv already installed ($(zv --version 2>/dev/null || true))"
fi

# lenticel: source shell-setup in interactive shells
echo ". ~/.config/lenticel/shell-setup.sh 2>/dev/null || true" >> ~/.bashrc
if [ -f ~/.zshrc ]; then
  echo ". ~/.config/lenticel/shell-setup.sh 2>/dev/null || true" >> ~/.zshrc
fi

# lenticel: install frpc + lenticel wrapper + frpc.toml
bash "$DOTFILES_DIR/lenticel-bootstrap.sh"
