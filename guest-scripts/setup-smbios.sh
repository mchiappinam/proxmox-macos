#!/bin/bash
#
# setup-smbios.sh
# Run inside the macOS VM to install OpenCore to EFI and generate SMBIOS
#
# Usage: curl -fsSL https://raw.githubusercontent.com/mchiappinam/proxmox-macos/main/guest-scripts/setup-smbios.sh | bash
#

set -e

EFI_MOUNT="/Volumes/EFI"
OC_VOLUME="/Volumes/LongQT-OpenCore"
CONFIG="$EFI_MOUNT/EFI/OC/config.plist"

echo ""
echo "     #############################################"
echo "     #                                           #"
echo "     #      macOS VM Post-Install Setup          #"
echo "     #                                           #"
echo "     #        Developed by mchiappinam           #"
echo "     #         github.com/mchiappinam            #"
echo "     #                                           #"
echo "     #############################################"
echo ""

# Check we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: This script must be run inside a macOS VM."
  exit 1
fi

# Check LongQT volume is mounted
if [[ ! -d "$OC_VOLUME" ]]; then
  echo "Error: LongQT-OpenCore volume not found."
  echo "Make sure the OpenCore ISO is attached to the VM."
  exit 1
fi

# Mount EFI partition
echo "Mounting EFI partition..."
if [[ ! -d "$EFI_MOUNT" ]]; then
  mkdir -p "$EFI_MOUNT" 2>/dev/null || true
fi

# Find the EFI partition on the boot disk
BOOT_DISK=$(diskutil info / | grep "Part of Whole" | awk '{print $NF}')
EFI_PART="${BOOT_DISK}s1"

if ! diskutil info "$EFI_PART" 2>/dev/null | grep -q "EFI"; then
  echo "Error: Could not find EFI partition on $BOOT_DISK"
  exit 1
fi

sudo diskutil mount -mountPoint "$EFI_MOUNT" "$EFI_PART"
echo "EFI mounted at $EFI_MOUNT"

# Copy OpenCore EFI if not present
if [[ ! -f "$CONFIG" ]]; then
  echo ""
  echo "Installing OpenCore to EFI partition..."
  cp -r "$OC_VOLUME/EFI_RELEASE/EFI" "$EFI_MOUNT/"
  echo "OpenCore installed."
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config.plist not found after copy"
  exit 1
fi

echo ""
echo "Current SMBIOS values:"
echo "  SystemProductName:  $(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemSerialNumber: $(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  MLB:                $(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemUUID:         $(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo ""

# Ask user what to do
echo "Options:"
echo "  1 - Enter SMBIOS values manually"
echo "  2 - Generate new SMBIOS automatically (requires GenSMBIOS)"
echo "  3 - Skip SMBIOS setup"
echo ""
read -rp "Choice [1]: " choice
choice="${choice:-1}"

if [[ "$choice" == "3" ]]; then
  echo "Skipped."
  exit 0
fi

if [[ "$choice" == "2" ]]; then
  # Try to use GenSMBIOS
  GENSMBIOS="$OC_VOLUME/GenSMBIOS/GenSMBIOS.py"
  if [[ ! -f "$GENSMBIOS" ]]; then
    # Copy to writable location
    cp -r "$OC_VOLUME/GenSMBIOS" /tmp/GenSMBIOS 2>/dev/null || true
    GENSMBIOS="/tmp/GenSMBIOS/GenSMBIOS.py"
  fi

  if [[ -f "$GENSMBIOS" ]] && command -v python3 &>/dev/null; then
    echo ""
    echo "Run GenSMBIOS manually:"
    echo "  cd /tmp/GenSMBIOS && python3 GenSMBIOS.py"
    echo ""
    echo "Select option 1 (Install MacSerial), then 3 (Generate SMBIOS)."
    echo "Enter iMacPro1,1 as the model."
    echo "Then re-run this script with option 1 to enter the values."
    exit 0
  else
    echo "GenSMBIOS or python3 not available. Use option 1 instead."
    choice="1"
  fi
fi

if [[ "$choice" == "1" ]]; then
  echo ""
  echo "Enter your SMBIOS values (from GenSMBIOS output):"
  echo ""

  read -rp "  SystemProductName [iMacPro1,1]: " smbios_type
  smbios_type="${smbios_type:-iMacPro1,1}"

  read -rp "  SystemSerialNumber: " serial
  if [[ -z "$serial" ]]; then
    echo "Error: Serial is required"
    exit 1
  fi

  read -rp "  Board Serial (MLB): " mlb
  if [[ -z "$mlb" ]]; then
    echo "Error: MLB is required"
    exit 1
  fi

  read -rp "  SmUUID: " uuid
  if [[ -z "$uuid" ]]; then
    echo "Error: UUID is required"
    exit 1
  fi

  read -rp "  Apple ROM [442A6077B912]: " rom
  rom="${rom:-442A6077B912}"

  # Confirm
  echo ""
  echo "  Will set:"
  echo "    SystemProductName:  $smbios_type"
  echo "    SystemSerialNumber: $serial"
  echo "    MLB:                $mlb"
  echo "    SystemUUID:         $uuid"
  echo "    ROM:                $rom"
  echo ""
  read -rp "  Apply? [Y/n]: " confirm
  if [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi

  # Backup
  cp "$CONFIG" "${CONFIG}.backup"
  echo "Backup saved to ${CONFIG}.backup"

  # Apply using plutil
  plutil -replace PlatformInfo.Generic.SystemProductName -string "$smbios_type" "$CONFIG"
  plutil -replace PlatformInfo.Generic.SystemSerialNumber -string "$serial" "$CONFIG"
  plutil -replace PlatformInfo.Generic.MLB -string "$mlb" "$CONFIG"
  plutil -replace PlatformInfo.Generic.SystemUUID -string "$uuid" "$CONFIG"

  # ROM is stored as data, convert hex to base64
  rom_base64=$(echo -n "$rom" | xxd -r -p | base64)
  plutil -replace PlatformInfo.Generic.ROM -data "$rom_base64" "$CONFIG"

  echo ""
  echo "SMBIOS updated successfully!"
  echo ""
  echo "New values:"
  echo "  SystemProductName:  $(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG")"
  echo "  SystemSerialNumber: $(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG")"
  echo "  MLB:                $(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG")"
  echo "  SystemUUID:         $(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG")"
  echo ""
  echo "Reboot to apply changes:"
  echo "  sudo reboot"
fi
