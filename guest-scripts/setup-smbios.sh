#!/bin/bash
#
# setup-smbios.sh
# Run inside the macOS VM to install OpenCore to EFI and configure SMBIOS
#
# Usage (download and run):
#   curl -fsSL https://raw.githubusercontent.com/mchiappinam/proxmox-macos/main/guest-scripts/setup-smbios.sh -o /tmp/setup-smbios.sh && bash /tmp/setup-smbios.sh
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

# Find the EFI partition by checking s1 on each disk
EFI_PART=""
for i in 0 1 2 3 4 5; do
  candidate="disk${i}s1"
  if diskutil info "$candidate" 2>/dev/null | grep -qi "EFI"; then
    EFI_PART="$candidate"
    break
  fi
done

if [[ -z "$EFI_PART" ]]; then
  echo "Error: Could not find any EFI partition"
  echo ""
  echo "Available disks:"
  diskutil list
  exit 1
fi

echo "  Found EFI partition: $EFI_PART"
sudo diskutil mount -mountPoint "$EFI_MOUNT" "$EFI_PART"

# Verify it actually mounted by checking for content
if ! mount | grep -q "$EFI_MOUNT"; then
  echo "Error: EFI partition failed to mount"
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
  echo "Error: config.plist not found after install"
  exit 1
fi

# ── Step 3: Install VMHide.kext (required for Sequoia/Sonoma iServices) ──────
KEXTS_DIR="$EFI_MOUNT/EFI/OC/Kexts"
VMHIDE_URL="https://github.com/Carnations-Botanica/VMHide/releases/download/2.0.0/VMHide-2.0.0-RELEASE.zip"

if [[ -d "$KEXTS_DIR/VMHide.kext" ]]; then
  echo ""
  echo "Step 3: VMHide.kext already installed."
else
  echo ""
  echo "Step 3: Installing VMHide.kext..."
  echo "  Required for Apple ID/iCloud on macOS Sonoma and Sequoia."
  echo ""

  local_tmp=$(mktemp -d)
  trap "rm -rf '$local_tmp'" EXIT

  if curl -fsSL -o "$local_tmp/VMHide.zip" "$VMHIDE_URL"; then
    unzip -q -o "$local_tmp/VMHide.zip" -d "$local_tmp/extract" 2>/dev/null || true

    # Find VMHide.kext in the extracted files
    VMHIDE_KEXT=$(find "$local_tmp/extract" -name "VMHide.kext" -type d | head -1)

    if [[ -n "$VMHIDE_KEXT" && -d "$VMHIDE_KEXT" ]]; then
      cp -r "$VMHIDE_KEXT" "$KEXTS_DIR/"
      echo "  VMHide.kext copied to Kexts folder."

      # Check if VMHide is already in config.plist to avoid duplicates
      if ! grep -q "VMHide.kext" "$CONFIG" 2>/dev/null; then
        # Find the last kext entry index
        last_idx=0
        while plutil -extract Kernel.Add.$last_idx raw "$CONFIG" &>/dev/null; do
          ((last_idx++))
        done

        # Add new entry at the end (single-line JSON for compatibility)
        plutil -insert Kernel.Add.$last_idx -json '{"Arch":"x86_64","BundlePath":"VMHide.kext","Comment":"Hides VM detection for iServices","Enabled":true,"ExecutablePath":"Contents/MacOS/VMHide","MaxKernel":"","MinKernel":"","PlistPath":"Contents/Info.plist"}' "$CONFIG" 2>/dev/null

        echo "  VMHide.kext added to config.plist."
      else
        echo "  VMHide.kext already in config.plist."
      fi
    else
      echo "  Warning: Could not find VMHide.kext in download."
      echo "  Download manually from: https://github.com/Carnations-Botanica/VMHide/releases"
    fi
  else
    echo "  Warning: Failed to download VMHide.kext."
    echo "  Download manually from: https://github.com/Carnations-Botanica/VMHide/releases"
  fi

  rm -rf "$local_tmp"
  trap - EXIT
fi

# ── Step 4: Show current SMBIOS ──────────────────────────────────────────────
echo ""
echo "Step 4: Current SMBIOS configuration:"
echo ""
echo "  SystemProductName:  $(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemSerialNumber: $(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  MLB:                $(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG" 2>/dev/null || echo 'unknown')"
echo "  SystemUUID:         $(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG" 2>/dev/null || echo 'unknown')"

# ── Step 5: Generate SMBIOS ──────────────────────────────────────────────────
echo ""
echo "Step 5: Generate unique SMBIOS serials"
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

# ── Step 6: Enter values (read from /dev/tty for curl|bash compatibility) ────
cur_type=$(plutil -extract PlatformInfo.Generic.SystemProductName raw "$CONFIG" 2>/dev/null || echo "")
cur_serial=$(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw "$CONFIG" 2>/dev/null || echo "")
cur_mlb=$(plutil -extract PlatformInfo.Generic.MLB raw "$CONFIG" 2>/dev/null || echo "")
cur_uuid=$(plutil -extract PlatformInfo.Generic.SystemUUID raw "$CONFIG" 2>/dev/null || echo "")

read -rp "  SystemProductName [$cur_type]: " new_type </dev/tty
new_type="${new_type:-$cur_type}"

read -rp "  Serial: " new_serial </dev/tty
if [[ -z "$new_serial" ]]; then
  echo "  Keeping current serial."
  new_serial="$cur_serial"
fi

read -rp "  Board Serial (MLB): " new_mlb </dev/tty
if [[ -z "$new_mlb" ]]; then
  echo "  Keeping current MLB."
  new_mlb="$cur_mlb"
fi

read -rp "  SmUUID: " new_uuid </dev/tty
if [[ -z "$new_uuid" ]]; then
  echo "  Keeping current UUID."
  new_uuid="$cur_uuid"
fi

read -rp "  Apple ROM [442A6077B912]: " new_rom </dev/tty
new_rom="${new_rom:-442A6077B912}"

# ── Step 7: Confirm and apply ────────────────────────────────────────────────
echo ""
echo "  Will set:"
echo "    SystemProductName:  $new_type"
echo "    SystemSerialNumber: $new_serial"
echo "    MLB:                $new_mlb"
echo "    SystemUUID:         $new_uuid"
echo "    ROM:                $new_rom"
echo ""
read -rp "  Apply these values? [Y/n]: " confirm </dev/tty
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
