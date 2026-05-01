#!/bin/bash
#
# setup-smbios.sh
# Run inside the macOS VM to install OpenCore to EFI and configure SMBIOS
#
# Usage: curl -fsSL https://raw.githubusercontent.com/mchiappinam/proxmox-macos/main/guest-scripts/setup-smbios.sh | bash
#

set -e

EFI_MOUNT="/Volumes/EFI"
OC_VOLUME="/Volumes/LongQT-OpenCore"
CONFIG=""

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

# ── Step 1: Mount EFI ─────────────────────────────────────────────────────────
echo "Step 1: Mounting EFI partition..."
echo ""

BOOT_DISK=$(diskutil info / | grep "Part of Whole" | awk '{print $NF}')
EFI_PART="${BOOT_DISK}s1"

if ! diskutil info "$EFI_PART" 2>/dev/null | grep -q "EFI"; then
  echo "Error: Could not find EFI partition on $BOOT_DISK"
  exit 1
fi

sudo diskutil mount -mountPoint "$EFI_MOUNT" "$EFI_PART" 2>/dev/null || true

if [[ ! -d "$EFI_MOUNT" ]]; then
  echo "Error: Failed to mount EFI partition"
  exit 1
fi

echo "  EFI mounted at $EFI_MOUNT"

# ── Step 2: Install OpenCore to EFI ──────────────────────────────────────────
CONFIG="$EFI_MOUNT/EFI/OC/config.plist"

if [[ ! -f "$CONFIG" ]]; then
  echo ""
  echo "Step 2: Installing OpenCore to EFI partition..."
  cp -r "$OC_VOLUME/EFI_RELEASE/EFI" "$EFI_MOUNT/"
  echo "  OpenCore installed to EFI partition."
  echo "  You can remove the OpenCore ISO from the VM after this."
else
  echo ""
  echo "Step 2: OpenCore already installed on EFI partition."
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config.plist not found"
  exit 1
fi

# ── Step 3: Show current SMBIOS ──────────────────────────────────────────────
echo ""
echo "Step 3: Current SMBIOS configuration:"
echo ""
echo "  SystemProductName:  $(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemSerialNumber: $(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  MLB:                $(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemUUID:         $(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG" 2>/dev/null || echo 'unknown')"

# ── Step 4: Generate SMBIOS ──────────────────────────────────────────────────
echo ""
echo "Step 4: Generate unique SMBIOS serials"
echo ""
echo "  You need unique serials for Apple ID and iCloud to work."
echo ""

# Prepare GenSMBIOS in a writable location
GENSMBIOS_DIR="/tmp/GenSMBIOS"
if [[ ! -d "$GENSMBIOS_DIR" ]]; then
  cp -r "$OC_VOLUME/GenSMBIOS" "$GENSMBIOS_DIR" 2>/dev/null || true
fi

if [[ -f "$GENSMBIOS_DIR/GenSMBIOS.py" ]] && command -v python3 &>/dev/null; then
  echo "  GenSMBIOS is ready. Open a NEW Terminal window and run:"
  echo ""
  echo "    cd /tmp/GenSMBIOS && python3 GenSMBIOS.py"
  echo ""
  echo "  In GenSMBIOS:"
  echo "    1. Select option 1 (Install/Update MacSerial)"
  echo "    2. Select option 3 (Generate SMBIOS)"
  echo "    3. Enter: iMacPro1,1"
  echo "    4. Copy the Serial, Board Serial, SmUUID, and Apple ROM"
  echo ""
  echo "  Then verify the serial at https://checkcoverage.apple.com"
  echo "  It should say 'not valid' (meaning it's not a real Mac)."
  echo ""
elif ! command -v python3 &>/dev/null; then
  echo "  Python 3 is not installed. Install it first:"
  echo ""
  echo "    Open the LongQT-OpenCore volume and run Install_Python3.command"
  echo "    Then re-run this script."
  echo ""
  exit 1
else
  echo "  GenSMBIOS not found on the OpenCore volume."
  echo "  Download it from: https://github.com/corpnewt/GenSMBIOS"
  echo ""
fi

echo "  Once you have the values, enter them below."
echo "  Press Enter to skip a field and keep the current value."
echo ""

# ── Step 5: Enter values ─────────────────────────────────────────────────────
cur_type=$(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG" 2>/dev/null || echo "")
cur_serial=$(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG" 2>/dev/null || echo "")
cur_mlb=$(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG" 2>/dev/null || echo "")
cur_uuid=$(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG" 2>/dev/null || echo "")

read -rp "  SystemProductName [$cur_type]: " new_type
new_type="${new_type:-$cur_type}"

read -rp "  Serial: " new_serial
if [[ -z "$new_serial" ]]; then
  echo "  Keeping current serial."
  new_serial="$cur_serial"
fi

read -rp "  Board Serial (MLB): " new_mlb
if [[ -z "$new_mlb" ]]; then
  echo "  Keeping current MLB."
  new_mlb="$cur_mlb"
fi

read -rp "  SmUUID: " new_uuid
if [[ -z "$new_uuid" ]]; then
  echo "  Keeping current UUID."
  new_uuid="$cur_uuid"
fi

read -rp "  Apple ROM [442A6077B912]: " new_rom
new_rom="${new_rom:-442A6077B912}"

# ── Step 6: Confirm and apply ────────────────────────────────────────────────
echo ""
echo "  Will set:"
echo "    SystemProductName:  $new_type"
echo "    SystemSerialNumber: $new_serial"
echo "    MLB:                $new_mlb"
echo "    SystemUUID:         $new_uuid"
echo "    ROM:                $new_rom"
echo ""
read -rp "  Apply these values? [Y/n]: " confirm
if [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]]; then
  echo "  Cancelled."
  exit 0
fi

# Backup
cp "$CONFIG" "${CONFIG}.backup"
echo ""
echo "  Backup saved to ${CONFIG}.backup"

# Apply using plutil (native macOS tool)
plutil -replace PlatformInfo.Generic.SystemProductName -string "$new_type" "$CONFIG"
plutil -replace PlatformInfo.Generic.SystemSerialNumber -string "$new_serial" "$CONFIG"
plutil -replace PlatformInfo.Generic.MLB -string "$new_mlb" "$CONFIG"
plutil -replace PlatformInfo.Generic.SystemUUID -string "$new_uuid" "$CONFIG"

# ROM is stored as data, convert hex to base64
rom_base64=$(echo -n "$new_rom" | xxd -r -p | base64)
plutil -replace PlatformInfo.Generic.ROM -data "$rom_base64" "$CONFIG"

echo ""
echo "  SMBIOS updated successfully!"
echo ""
echo "  Verify:"
echo "    SystemProductName:  $(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG")"
echo "    SystemSerialNumber: $(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG")"
echo "    MLB:                $(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG")"
echo "    SystemUUID:         $(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG")"
echo ""
echo "  Reboot to apply: sudo reboot"
echo ""
