#!/bin/bash
#
# One-liner installer for proxmox-macos
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/mchiappinam/proxmox-macos/main/install.sh)
#
set -e

REPO="mchiappinam/proxmox-macos"
INSTALL_DIR="/opt/proxmox-macos"
BRANCH="main"

echo ""
echo "  proxmox-macos installer"
echo "  ━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Root check
if [[ "$EUID" -ne 0 ]]; then
  echo "Error: Must run as root"
  exit 1
fi

# Proxmox check
if ! command -v qm &>/dev/null; then
  echo "Error: This tool requires Proxmox VE."
  echo "       Run this on a Proxmox VE host."
  exit 1
fi

# Install git if missing
if ! command -v git &>/dev/null; then
  echo "Installing git..."
  apt-get update -qq && apt-get install -y -qq git
fi

# Clone or update
if [[ -d "$INSTALL_DIR" ]]; then
  echo "Updating existing installation..."
  cd "$INSTALL_DIR"
  git pull --rebase origin "$BRANCH" 2>/dev/null || {
    echo "Update failed, re-cloning..."
    cd /
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "https://github.com/${REPO}.git" "$INSTALL_DIR"
  }
else
  echo "Installing to $INSTALL_DIR..."
  git clone --depth 1 "https://github.com/${REPO}.git" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/macos-vm-manager.sh"

# Create symlink for easy access
ln -sf "$INSTALL_DIR/macos-vm-manager.sh" /usr/local/bin/macos-vm

echo ""
echo "  ✓ Installed successfully!"
echo ""
echo "  Run it with:"
echo "    macos-vm"
echo ""
echo "  Or directly:"
echo "    $INSTALL_DIR/macos-vm-manager.sh"
echo ""
echo "  To update later:"
echo "    cd $INSTALL_DIR && git pull"
echo ""
