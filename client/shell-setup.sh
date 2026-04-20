#!/usr/bin/env bash
# lenticel shell integration — installed to ~/.config/lenticel/shell-setup.sh
# and sourced from .bashrc / .zshrc by purse/install.sh.

# Add ~/.local/bin to PATH (idempotent)
case ":${PATH}:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# Short alias
alias lt='lenticel'
