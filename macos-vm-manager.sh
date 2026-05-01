#!/bin/bash
#
# macos-vm-manager.sh
# Interactive macOS VM manager for Proxmox VE
# Uses LongQT OpenCore ISO, no host-level modifications
#
# Developed by mchiappinam
# https://github.com/mchiappinam/proxmox-macos
#
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/macos-vm-manager.log"
OPENCORE_ISO="LongQT-OpenCore-v0.7.iso"
MACRECOVERY_DIR="${SCRIPT_DIR}/tools/macrecovery"
MACRECOVERY_URL="https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py"
MACOS_TAG="[macos-vm-manager]"  # tag added to VM description for reliable detection

# Global state (set by detect_cpu, select_storage, etc.)
CPU_PLATFORM=""
CPU_TYPE=""
CPU_ARGS=""
SELECTED_STORAGE=""
SELECTED_BRIDGE=""
ISO_STORAGE=""

# macOS versions: name|version|board_id|model_id|recovery_size
declare -A MACOS_VERSIONS=(
  [1]="High Sierra|10.13|Mac-BE088AF8C5EB4FA2|00000000000J80300|800M"
  [2]="Mojave|10.14|Mac-7BA5B2DFE22DDD8C|00000000000KXPG00|800M"
  [3]="Catalina|10.15|Mac-00BE6ED71E35EB86|00000000000000000|800M"
  [4]="Big Sur|11|Mac-42FD25EABCABB274|00000000000000000|1024M"
  [5]="Monterey|12|Mac-E43C1C25D4880AD6|00000000000000000|1024M"
  [6]="Ventura|13|Mac-B4831CEBD52A0C4C|00000000000000000|1024M"
  [7]="Sonoma|14|Mac-827FAC58A8FDFA22|00000000000000000|1450M"
  [8]="Sequoia|15|Mac-7BA5B2D9E42DDD94|00000000000000000|1450M"
)

# ── Logging ───────────────────────────────────────────────────────────────────
init_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_and_print() {
  echo "$1"
  log "$1"
}

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
  cat <<EOF
macOS VM Manager v${VERSION} for Proxmox VE

Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help      Show this help message
  -v, --version   Show version
  --preflight     Run pre-flight check and exit

Without options, launches the interactive menu.

Requirements:
  - Proxmox VE 7.x, 8.x, or 9.x
  - Root access
  - Intel or AMD CPU with VT-x/SVM
  - Internet access (for downloading OpenCore ISO and macOS recovery)
EOF
  exit 0
}

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Must run as root"
    exit 1
  fi
}

# ── Dependency check ──────────────────────────────────────────────────────────
check_dependencies() {
  local missing=()

  # Must be Proxmox
  if ! command -v qm &>/dev/null; then
    echo "Error: 'qm' not found. This tool requires Proxmox VE."
    echo "       It must be run directly on a Proxmox VE host."
    exit 1
  fi

  # Required tools
  for cmd in pvesm pvesh losetup mount umount wget bc python3 mkfs.msdos; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing[*]}"
    echo ""

    # Map commands to packages
    local pkgs=()
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        python3)      pkgs+=("python3") ;;
        wget)         pkgs+=("wget") ;;
        bc)           pkgs+=("bc") ;;
        mkfs.msdos)   pkgs+=("dosfstools") ;;
        losetup)      pkgs+=("util-linux") ;;
        *)            pkgs+=("$cmd") ;;
      esac
    done

    # Deduplicate
    local unique_pkgs
    readarray -t unique_pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    echo "Install them with:"
    echo "  apt-get install -y ${unique_pkgs[*]}"
    echo ""
    read -rp "Install now? [Y/n]: " install_choice
    if [[ "${install_choice:-Y}" =~ ^[Yy]$ ]]; then
      apt-get update -qq
      apt-get install -y "${unique_pkgs[@]}"
    else
      exit 1
    fi
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────
# Check if a VM config is a macOS VM managed by this tool
is_macos_vm() {
  local conf="$1"
  [[ -f "$conf" ]] || return 1
  # Primary: check for our tag in description
  if grep -q "$MACOS_TAG" "$conf" 2>/dev/null; then
    return 0
  fi
  # Fallback: check for macOS-specific QEMU args or CPU models
  if grep -qE "Broadwell-noTSX|Skylake-Client-v4|Skylake-Server-v4|Haswell-noTSX|opencore|OpenCore" "$conf" 2>/dev/null; then
    return 0
  fi
  return 1
}

# List macOS VMs and populate MACOS_VM_IDS array
find_macos_vms() {
  MACOS_VM_IDS=()
  for conf in /etc/pve/qemu-server/*.conf; do
    [[ ! -f "$conf" ]] && continue
    if is_macos_vm "$conf"; then
      MACOS_VM_IDS+=("$(basename "$conf" .conf)")
    fi
  done
}


# ── CPU Detection ─────────────────────────────────────────────────────────────
detect_cpu() {
  local model_name vendor
  model_name=$(lscpu | grep "Model name" | sed 's/.*: *//')
  vendor=$(lscpu | grep "Vendor ID" | sed 's/.*: *//')

  if [[ "$vendor" == *"AMD"* ]]; then
    CPU_PLATFORM="AMD"
    if grep -q 'avx512f' /proc/cpuinfo 2>/dev/null; then
      CPU_TYPE="Skylake-Server-v4"
      CPU_ARGS="-cpu Skylake-Server-v4,vendor=GenuineIntel"
    elif grep -q 'avx2' /proc/cpuinfo 2>/dev/null; then
      CPU_TYPE="Skylake-Client-v4"
      CPU_ARGS="-cpu Skylake-Client-v4,vendor=GenuineIntel"
    else
      CPU_TYPE="Nehalem"
      CPU_ARGS="-cpu Nehalem,vendor=GenuineIntel"
    fi
  else
    CPU_PLATFORM="INTEL"
    if [[ "$model_name" =~ E[57].*v[34] ]]; then
      # Broadwell/Haswell HEDT (Xeon E5/E7 v3 or v4) — needs CPUID model override
      CPU_TYPE="Broadwell-noTSX"
      CPU_ARGS="-cpu Broadwell-noTSX,model=158"
    elif [[ "$model_name" =~ E[57].*v2 ]]; then
      # Ivy Bridge HEDT
      CPU_TYPE="Haswell-noTSX"
      CPU_ARGS="-cpu Haswell-noTSX,model=158,stepping=3"
    elif grep -q 'avx512f' /proc/cpuinfo 2>/dev/null; then
      CPU_TYPE="Skylake-Server-v4"
      CPU_ARGS="-cpu Skylake-Server-v4"
    elif grep -q 'avx2' /proc/cpuinfo 2>/dev/null; then
      CPU_TYPE="Skylake-Client-v4"
      CPU_ARGS="-cpu Skylake-Client-v4"
    else
      CPU_TYPE="Haswell-noTSX"
      CPU_ARGS="-cpu Haswell-noTSX"
    fi
  fi

  log "Detected CPU: $model_name | Platform: $CPU_PLATFORM | QEMU type: $CPU_TYPE"
}

# ── Pre-flight Check ──────────────────────────────────────────────────────────
preflight_check() {
  clear
  echo -e "${BOLD}Pre-flight System Check${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local pass=true

  # KVM
  if grep -qw "kvm" /proc/modules 2>/dev/null; then
    ok "KVM module loaded"
  else
    fail "KVM module not loaded"
    pass=false
  fi

  # VT-x / SVM
  local virt_type
  virt_type=$(grep -oE '(vmx|svm)' /proc/cpuinfo | head -1) || true
  if [[ -n "$virt_type" ]]; then
    ok "Hardware virtualization: $virt_type"
  else
    fail "No hardware virtualization (vmx/svm) found"
    pass=false
  fi

  # SSE4.1
  if grep -q 'sse4_1' /proc/cpuinfo; then
    ok "SSE4.1 supported"
  else
    fail "SSE4.1 not supported (required for macOS Sierra+)"
    pass=false
  fi

  # AVX2
  if grep -q 'avx2' /proc/cpuinfo; then
    ok "AVX2 supported (Ventura+ compatible)"
  else
    warn "AVX2 not supported (limited to macOS Monterey)"
  fi

  # QEMU version
  local qemu_ver
  qemu_ver=$(qemu-system-x86_64 --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
  if [[ -n "$qemu_ver" ]]; then
    ok "QEMU version: $qemu_ver"
  else
    fail "QEMU not installed"
    pass=false
  fi

  # IOMMU
  if dmesg 2>/dev/null | grep -qi "IOMMU enabled\|DMAR:.*IOMMU\|AMD-Vi:"; then
    ok "IOMMU enabled"
  else
    warn "IOMMU may not be enabled (GPU passthrough won't work)"
  fi

  # TSC
  if dmesg 2>/dev/null | grep -q "clocksource: Switched to clocksource tsc"; then
    ok "TSC clocksource active"
  else
    warn "TSC clocksource not active (may cause timer issues)"
  fi

  # OpenCore ISO
  if find_opencore_iso; then
    ok "OpenCore ISO found: ${OC_ISO_STORAGE}:iso/${OPENCORE_ISO}"
  else
    fail "OpenCore ISO not found: $OPENCORE_ISO"
    read -rp "    Download it now? [Y/n]: " dl_oc
    if [[ "${dl_oc:-Y}" =~ ^[Yy]$ ]]; then
      if download_opencore_iso; then
        ok "OpenCore ISO downloaded"
      else
        pass=false
      fi
    else
      info "Download from: https://github.com/LongQT-sea/OpenCore-ISO/releases"
      pass=false
    fi
  fi

  # CPU detection
  detect_cpu
  ok "CPU model for macOS: $CPU_TYPE ($CPU_PLATFORM)"

  echo ""
  if $pass; then
    echo -e "${GREEN}All critical checks passed. Ready to create macOS VMs.${NC}"
  else
    echo -e "${RED}Some checks failed. Fix the issues above before creating VMs.${NC}"
  fi
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}


# ── Storage helpers ───────────────────────────────────────────────────────────
select_storage() {
  local content_type=$1  # "images" or "iso"
  local prompt_label=$2
  local storages=()
  local default_storage=""
  local max_avail=0

  while IFS= read -r line; do
    [[ "$line" =~ ^Name ]] && continue
    local sname stype sstatus stotal sused savail spct
    read -r sname stype sstatus stotal sused savail spct <<< "$line"
    [[ "$sstatus" != "active" ]] && continue
    [[ ! "$savail" =~ ^[0-9]+$ || "$savail" -eq 0 ]] && continue
    local avail_gb
    avail_gb=$(echo "scale=1; $savail / 1024 / 1024" | bc 2>/dev/null) || avail_gb="?"
    storages+=("${sname}|${avail_gb}")
    if (( savail > max_avail )); then
      max_avail=$savail
      default_storage="$sname"
    fi
  done <<< "$(pvesm status --content "$content_type" 2>/dev/null)"

  if [[ ${#storages[@]} -eq 0 ]]; then
    log_and_print "Error: No active $content_type storages found"
    return 1
  fi

  if [[ ${#storages[@]} -eq 1 ]]; then
    SELECTED_STORAGE="${storages[0]%%|*}"
    info "Using $prompt_label storage: $SELECTED_STORAGE"
    return 0
  fi

  echo "  Available $prompt_label storages:"
  for s in "${storages[@]}"; do
    echo "    - ${s%%|*} (${s##*|} GB free)"
  done
  while true; do
    read -rp "  $prompt_label storage [$default_storage]: " choice
    choice="${choice:-$default_storage}"
    for s in "${storages[@]}"; do
      if [[ "$choice" == "${s%%|*}" ]]; then
        SELECTED_STORAGE="$choice"
        return 0
      fi
    done
    echo "  Invalid storage. Try again."
  done
}

# ── Bridge helper ─────────────────────────────────────────────────────────────
select_bridge() {
  local bridges=()
  local default_bridge="vmbr0"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^iface\ (vmbr[0-9]+) ]]; then
      local bname="${BASH_REMATCH[1]}"
      [[ ! -d "/sys/class/net/$bname" ]] && continue
      local addr
      addr=$(ip -4 addr show "$bname" 2>/dev/null | awk '/inet/ {print $2}' | cut -d'/' -f1 | head -1) || true
      bridges+=("${bname}|${addr:-no IP}")
    fi
  done < /etc/network/interfaces

  if [[ ${#bridges[@]} -eq 0 ]]; then
    SELECTED_BRIDGE="vmbr0"
    warn "No bridges detected, defaulting to vmbr0"
    return 0
  fi

  if [[ ${#bridges[@]} -eq 1 ]]; then
    SELECTED_BRIDGE="${bridges[0]%%|*}"
    info "Using bridge: $SELECTED_BRIDGE"
    return 0
  fi

  echo "  Available bridges:"
  for b in "${bridges[@]}"; do
    echo "    - ${b%%|*} (${b##*|})"
  done
  while true; do
    read -rp "  Bridge [$default_bridge]: " choice
    choice="${choice:-$default_bridge}"
    for b in "${bridges[@]}"; do
      if [[ "$choice" == "${b%%|*}" ]]; then
        SELECTED_BRIDGE="$choice"
        return 0
      fi
    done
    echo "  Invalid bridge. Try again."
  done
}


# ── OpenCore ISO download ─────────────────────────────────────────────────────
OPENCORE_DOWNLOAD_URL="https://github.com/LongQT-sea/OpenCore-ISO/releases/download/v0.7/LongQT-OpenCore-v0.7.iso"

# Find the OpenCore ISO across all ISO storages. Sets OC_ISO_PATH if found.
find_opencore_iso() {
  OC_ISO_PATH=""
  OC_ISO_STORAGE=""
  while IFS= read -r line; do
    [[ "$line" =~ ^Name ]] && continue
    local sname stype sstatus
    read -r sname stype sstatus _ <<< "$line"
    [[ "$sstatus" != "active" ]] && continue
    local spath
    spath=$(pvesm path "${sname}:iso/${OPENCORE_ISO}" 2>/dev/null) || continue
    if [[ -f "$spath" ]]; then
      OC_ISO_PATH="$spath"
      OC_ISO_STORAGE="$sname"
      return 0
    fi
  done <<< "$(pvesm status --content iso 2>/dev/null)"
  return 1
}

# Download OpenCore ISO to the specified storage (or first available ISO storage)
download_opencore_iso() {
  local target_storage="${1:-}"

  # If no target specified, pick the first available ISO storage
  if [[ -z "$target_storage" ]]; then
    select_storage "iso" "OpenCore ISO target" || return 1
    target_storage="$SELECTED_STORAGE"
  fi

  local iso_dir
  iso_dir=$(resolve_iso_dir "$target_storage")
  if [[ -z "$iso_dir" ]]; then
    fail "Could not resolve ISO directory for storage: $target_storage"
    return 1
  fi

  local iso_path="${iso_dir}/${OPENCORE_ISO}"

  if [[ -f "$iso_path" ]]; then
    ok "OpenCore ISO already exists: $iso_path"
    return 0
  fi

  info "Downloading LongQT OpenCore ISO..."
  info "Source: $OPENCORE_DOWNLOAD_URL"
  echo ""

  if ! wget -q --show-progress -O "$iso_path" "$OPENCORE_DOWNLOAD_URL" 2>&1; then
    fail "Failed to download OpenCore ISO"
    rm -f "$iso_path"
    return 1
  fi

  if [[ ! -s "$iso_path" ]]; then
    fail "Downloaded file is empty"
    rm -f "$iso_path"
    return 1
  fi

  ok "OpenCore ISO downloaded to: $iso_path"
  log "Downloaded OpenCore ISO to $iso_path"
  return 0
}

# Ensure OpenCore ISO is available — download if missing
ensure_opencore_iso() {
  if find_opencore_iso; then
    return 0
  fi

  echo ""
  warn "OpenCore ISO not found on any storage"
  read -rp "  Download it now? [Y/n]: " dl_choice
  if [[ "${dl_choice:-Y}" =~ ^[Yy]$ ]]; then
    download_opencore_iso || return 1
    # Re-check after download
    find_opencore_iso || {
      fail "OpenCore ISO still not found after download"
      return 1
    }
    return 0
  fi

  info "You can download it manually from:"
  info "  https://github.com/LongQT-sea/OpenCore-ISO/releases"
  return 1
}

# ── Recovery image download ───────────────────────────────────────────────────
ensure_macrecovery() {
  if [[ ! -f "${MACRECOVERY_DIR}/macrecovery.py" ]]; then
    log_and_print "  Downloading macrecovery.py..."
    mkdir -p "$MACRECOVERY_DIR"
    if ! wget -q -O "${MACRECOVERY_DIR}/macrecovery.py" "$MACRECOVERY_URL"; then
      log_and_print "Error: Failed to download macrecovery.py"
      return 1
    fi
    chmod +x "${MACRECOVERY_DIR}/macrecovery.py"
  fi
  if ! command -v python3 &>/dev/null; then
    log_and_print "  Installing python3..."
    apt-get update -qq >>"$LOG_FILE" 2>&1
    apt-get install -y -qq python3 >>"$LOG_FILE" 2>&1
  fi
}

# Resolve the filesystem path for an ISO storage
resolve_iso_dir() {
  local storage_name=$1
  local dir=""
  # Try pvesm path with a dummy file to get the directory
  dir=$(pvesm path "${storage_name}:iso/dummy.iso" 2>/dev/null | sed 's|/[^/]*$||') || true
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    # Fallback: query storage config
    local spath
    spath=$(pvesh get /storage/"${storage_name}" --output-format json 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('path',''))" 2>/dev/null) || true
    dir="${spath}/template/iso"
  fi
  mkdir -p "$dir" 2>/dev/null || true
  echo "$dir"
}

download_recovery() {
  local version_name=$1 board_id=$2 model_id=$3 iso_size=$4 target_storage=$5
  local iso_name="recovery-${version_name,,}.iso"
  local iso_dir
  iso_dir=$(resolve_iso_dir "$target_storage")

  if [[ -z "$iso_dir" ]]; then
    fail "Could not resolve ISO directory for storage: $target_storage"
    return 1
  fi

  local iso_path="${iso_dir}/${iso_name}"

  if [[ -f "$iso_path" ]]; then
    info "Recovery image already exists: $iso_name"
    read -rp "  Re-download? [y/N]: " redownload
    [[ ! "${redownload:-N}" =~ ^[Yy]$ ]] && return 0
    rm -f "$iso_path"
  fi

  ensure_macrecovery || return 1

  log_and_print "  Downloading $version_name recovery image (this may take a few minutes)..."
  local tmpdir
  tmpdir=$(mktemp -d)

  # Create FAT32 image
  if ! fallocate -l "$iso_size" "${tmpdir}/${iso_name}" 2>>"$LOG_FILE"; then
    fail "Failed to allocate image"
    rm -rf "$tmpdir"
    return 1
  fi
  mkfs.msdos -F 32 "${tmpdir}/${iso_name}" -n "${version_name^^}" >>"$LOG_FILE" 2>&1

  local loopdev
  loopdev=$(losetup -f --show "${tmpdir}/${iso_name}") || {
    fail "Failed to setup loop device"
    rm -rf "$tmpdir"
    return 1
  }

  mkdir -p /mnt/_macrecovery
  if ! mount "$loopdev" /mnt/_macrecovery 2>>"$LOG_FILE"; then
    fail "Failed to mount recovery image"
    losetup -d "$loopdev" 2>/dev/null
    rm -rf "$tmpdir"
    return 1
  fi

  local recovery_args="-b $board_id -m $model_id download"
  [[ "$version_name" == "Sequoia" ]] && recovery_args="$recovery_args -os latest"

  if ! (cd /mnt/_macrecovery && python3 "${MACRECOVERY_DIR}/macrecovery.py" $recovery_args) >>"$LOG_FILE" 2>&1; then
    fail "Failed to download recovery from Apple servers"
    umount /mnt/_macrecovery 2>/dev/null
    losetup -d "$loopdev" 2>/dev/null
    rmdir /mnt/_macrecovery 2>/dev/null
    rm -rf "$tmpdir"
    return 1
  fi

  umount /mnt/_macrecovery 2>/dev/null
  losetup -d "$loopdev" 2>/dev/null
  rmdir /mnt/_macrecovery 2>/dev/null

  mv "${tmpdir}/${iso_name}" "$iso_path"
  rm -rf "$tmpdir"

  ok "Recovery image created: $iso_name"
  log "Recovery image saved to: $iso_path"
}


# ── Create VM ─────────────────────────────────────────────────────────────────
create_macos_vm() {
  local opt=$1
  local config="${MACOS_VERSIONS[$opt]}"
  local version_name version board_id model_id iso_size
  IFS='|' read -r version_name version board_id model_id iso_size <<< "$config"

  clear
  echo -e "${BOLD}Create macOS $version_name VM${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  detect_cpu
  info "Detected CPU: $CPU_TYPE ($CPU_PLATFORM)"
  echo ""

  # VM ID
  local nextid
  nextid=$(pvesh get /cluster/nextid)
  local vmid
  while true; do
    read -rp "  VM ID [$nextid]: " vmid
    vmid="${vmid:-$nextid}"
    if [[ "$vmid" =~ ^[0-9]+$ ]] && [[ ! -e "/etc/pve/qemu-server/${vmid}.conf" ]]; then
      break
    fi
    echo "  Invalid or existing VM ID."
  done

  # VM Name
  local default_name="macOS-${version_name}"
  local vmname
  while true; do
    read -rp "  VM Name [$default_name]: " vmname
    vmname="${vmname:-$default_name}"
    if [[ "$vmname" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      break
    fi
    echo "  Invalid name. Use alphanumeric, dash, dot, underscore."
  done

  # Storage selection
  echo ""
  select_storage "images" "VM disk" || return
  local vm_storage="$SELECTED_STORAGE"

  select_storage "iso" "ISO" || return
  ISO_STORAGE="$SELECTED_STORAGE"

  # Ensure OpenCore ISO is available (auto-download if missing)
  if ! find_opencore_iso; then
    if ! download_opencore_iso "$ISO_STORAGE"; then
      fail "OpenCore ISO required but not available"
      read -n 1 -sp "Press any key to return to menu..."
      return
    fi
    # Update ISO_STORAGE to where we downloaded it
    find_opencore_iso || {
      fail "OpenCore ISO still not found after download"
      read -n 1 -sp "Press any key to return to menu..."
      return
    }
    ISO_STORAGE="$OC_ISO_STORAGE"
  else
    # Use the storage where OpenCore was found if user picked a different one
    ISO_STORAGE="$OC_ISO_STORAGE"
  fi

  # Bridge
  echo ""
  select_bridge

  # Cores
  echo ""
  local cores
  while true; do
    read -rp "  CPU cores [8]: " cores
    cores="${cores:-8}"
    if [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 && cores <= 64 )); then
      break
    fi
    echo "  Must be 1-64."
  done

  # RAM
  local ram
  while true; do
    read -rp "  RAM in MiB [16384]: " ram
    ram="${ram:-16384}"
    if [[ "$ram" =~ ^[0-9]+$ ]] && (( ram >= 2048 )); then
      break
    fi
    echo "  Minimum 2048 MiB."
  done

  # Disk
  local disk
  while true; do
    read -rp "  Disk size in GiB [128]: " disk
    disk="${disk:-128}"
    if [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 32 )); then
      break
    fi
    echo "  Minimum 32 GiB."
  done

  # Download recovery
  echo ""
  read -rp "  Download recovery image? [Y/n]: " dl_recovery
  if [[ "${dl_recovery:-Y}" =~ ^[Yy]$ ]]; then
    download_recovery "$version_name" "$board_id" "$model_id" "$iso_size" "$ISO_STORAGE" || {
      fail "Recovery download failed"
      read -n 1 -sp "Press any key to return to menu..."
      return
    }
  fi

  local recovery_iso="recovery-${version_name,,}.iso"

  # Network model, virtio for macOS 11+, vmxnet3 for 10.11-10.15, e1000 for older
  local net_model="virtio"
  case "$version" in
    10.13|10.14|10.15) net_model="vmxnet3" ;;
    10.*) net_model="e1000" ;;
  esac

  # Summary
  echo ""
  echo -e "${BOLD}  Summary:${NC}"
  echo "  ─────────────────────────────────────"
  echo "  VM ID:      $vmid"
  echo "  Name:       $vmname"
  echo "  macOS:      $version_name ($version)"
  echo "  CPU:        $cores cores ($CPU_TYPE)"
  echo "  RAM:        $ram MiB"
  echo "  Disk:       ${disk} GiB on $vm_storage"
  echo "  Network:    $net_model on $SELECTED_BRIDGE"
  echo "  OpenCore:   $OPENCORE_ISO"
  echo "  Recovery:   $recovery_iso"
  echo ""
  read -rp "  Create this VM? [Y/n]: " confirm
  [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]] && return

  local description="macOS ${version_name} VM ${MACOS_TAG}"

  log "Creating VM $vmid: $vmname ($version_name)"
  if ! qm create "$vmid" \
    --name "$vmname" \
    --description "$description" \
    --ostype other \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${vm_storage}:4" \
    --cpu "$CPU_TYPE" \
    --cores "$cores" \
    --sockets 1 \
    --memory "$ram" \
    --balloon 0 \
    --virtio0 "${vm_storage}:${disk},iothread=1" \
    --ide2 "${ISO_STORAGE}:iso/${OPENCORE_ISO},media=cdrom" \
    --ide0 "${ISO_STORAGE}:iso/${recovery_iso},media=cdrom" \
    --net0 "${net_model},bridge=${SELECTED_BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --vga std \
    --boot "order=ide2;virtio0;ide0" \
    --args "$CPU_ARGS" >>"$LOG_FILE" 2>&1; then
    fail "Failed to create VM. Check $LOG_FILE"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Auto-snapshot
  log "Creating initial snapshot for VM $vmid"
  if qm snapshot "$vmid" "fresh-vm" --description "Clean VM before first boot" >>"$LOG_FILE" 2>&1; then
    ok "Snapshot 'fresh-vm' created"
  else
    warn "Could not create snapshot (non-critical)"
  fi

  echo ""
  ok "VM $vmid ($vmname) created successfully!"
  echo ""
  echo -e "  ${BOLD}Installation Guide:${NC}"
  echo ""
  echo "  1. Start the VM:"
  echo "       qm start $vmid"
  echo ""
  echo "  2. Open the console in the Proxmox web UI"
  echo "     (select VM $vmid, click Console)"
  echo ""
  echo "  3. OpenCore will boot automatically."
  echo "     Select 'macOS Base System' or the recovery entry."
  echo "     Be patient, the first boot takes a few minutes."
  echo ""
  echo "  4. When the recovery screen appears:"
  echo "     a. Click 'Disk Utility', then Continue"
  echo "     b. Click View (top left) > Show All Devices"
  echo "     c. Select the top-level VirtIO disk (~${disk} GB)"
  echo "     d. Click Erase:"
  echo "          Name:    Macintosh HD"
  echo "          Format:  APFS"
  echo "          Scheme:  GUID Partition Map"
  echo "     e. Close Disk Utility"
  echo ""
  echo "  5. Click 'Reinstall macOS $version_name', then Continue"
  echo "     Select the disk you just erased and follow the prompts."
  echo ""
  echo "  6. The install will download from Apple and reboot a few times."
  echo "     Let OpenCore auto-boot each time, do not interrupt."
  echo "     This can take 30-60 minutes depending on your internet."
  echo ""
  echo "  7. After install, go through the macOS setup wizard."
  echo "     Tip: skip Apple ID login during setup, configure it later."
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}


# ── Clone VM ──────────────────────────────────────────────────────────────────
clone_macos_vm() {
  clear
  echo -e "${BOLD}Clone macOS VM${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  find_macos_vms
  if [[ ${#MACOS_VM_IDS[@]} -eq 0 ]]; then
    echo "  No macOS VMs found to clone."
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  echo "  Available macOS VMs:"
  for vid in "${MACOS_VM_IDS[@]}"; do
    local vname
    vname=$(grep "^name:" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null | awk '{print $2}')
    local vstatus
    vstatus=$(qm status "$vid" 2>/dev/null | awk '{print $2}') || vstatus="unknown"
    echo "    $vid - ${vname:-unnamed} ($vstatus)"
  done

  echo ""
  read -rp "  Source VM ID to clone: " source_id
  [[ -z "$source_id" ]] && return

  # Validate source
  local valid=false
  for v in "${MACOS_VM_IDS[@]}"; do
    [[ "$v" == "$source_id" ]] && valid=true
  done
  if ! $valid; then
    fail "VM $source_id is not a macOS VM"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Check if source is running
  local src_status
  src_status=$(qm status "$source_id" 2>/dev/null | awk '{print $2}') || true
  if [[ "$src_status" == "running" ]]; then
    warn "Source VM is running. Clone will be from current state (not a clean snapshot)."
    read -rp "  Continue? [y/N]: " cont
    [[ ! "${cont:-N}" =~ ^[Yy]$ ]] && return
  fi

  # New VM ID
  local nextid
  nextid=$(pvesh get /cluster/nextid)
  local new_id
  while true; do
    read -rp "  New VM ID [$nextid]: " new_id
    new_id="${new_id:-$nextid}"
    if [[ "$new_id" =~ ^[0-9]+$ ]] && [[ ! -e "/etc/pve/qemu-server/${new_id}.conf" ]]; then
      break
    fi
    echo "  Invalid or existing VM ID."
  done

  # New name
  local src_name
  src_name=$(grep "^name:" "/etc/pve/qemu-server/${source_id}.conf" 2>/dev/null | awk '{print $2}')
  local default_clone_name="${src_name:-macOS}-clone"
  local new_name
  while true; do
    read -rp "  New VM name [$default_clone_name]: " new_name
    new_name="${new_name:-$default_clone_name}"
    if [[ "$new_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      break
    fi
    echo "  Invalid name."
  done

  # Clone type
  echo ""
  echo "  Clone type:"
  echo "    1 - Full clone (independent copy, uses more disk space)"
  echo "    2 - Linked clone (shares base disk, faster, less space)"
  local clone_type
  read -rp "  Choice [1]: " clone_type
  clone_type="${clone_type:-1}"

  # Target storage for full clone
  local storage_arg=""
  if [[ "$clone_type" == "1" ]]; then
    select_storage "images" "Clone target" || return
    storage_arg="--storage $SELECTED_STORAGE"
  fi

  echo ""
  info "Cloning VM $source_id → $new_id ($new_name)..."

  local clone_cmd="qm clone $source_id $new_id --name $new_name"
  if [[ "$clone_type" == "1" ]]; then
    clone_cmd="$clone_cmd --full $storage_arg"
  fi

  if ! eval "$clone_cmd" >>"$LOG_FILE" 2>&1; then
    fail "Clone failed. Check $LOG_FILE"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Update description to include our tag
  local new_desc="Cloned from VM $source_id ${MACOS_TAG}"
  qm set "$new_id" --description "$new_desc" >>"$LOG_FILE" 2>&1 || true

  ok "VM $new_id ($new_name) cloned from $source_id"
  log "Cloned VM $source_id → $new_id ($new_name)"
  echo ""
  echo "  The clone is ready to start. No macOS reinstall needed."
  echo "  Note: You may want to generate a new SMBIOS serial if using iCloud."
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}

# ── Convert to Template ──────────────────────────────────────────────────────
convert_to_template() {
  clear
  echo -e "${BOLD}Convert macOS VM to Template${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  A template is a read-only base image. You can't start it directly,"
  echo "  but you can clone it instantly to create new macOS VMs without"
  echo "  reinstalling. Ideal after a clean macOS install + setup."
  echo ""

  find_macos_vms
  if [[ ${#MACOS_VM_IDS[@]} -eq 0 ]]; then
    echo "  No macOS VMs found."
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  echo "  Available macOS VMs:"
  for vid in "${MACOS_VM_IDS[@]}"; do
    local vname vstatus
    vname=$(grep "^name:" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null | awk '{print $2}')
    vstatus=$(qm status "$vid" 2>/dev/null | awk '{print $2}') || vstatus="unknown"
    # Check if already a template
    local is_tmpl=""
    grep -q "^template: 1" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null && is_tmpl=" [TEMPLATE]"
    echo "    $vid - ${vname:-unnamed} ($vstatus)${is_tmpl}"
  done

  echo ""
  read -rp "  VM ID to convert to template (or 0 to cancel): " tmpl_id
  [[ "$tmpl_id" == "0" || -z "$tmpl_id" ]] && return

  # Validate
  local valid=false
  for v in "${MACOS_VM_IDS[@]}"; do
    [[ "$v" == "$tmpl_id" ]] && valid=true
  done
  if ! $valid; then
    fail "VM $tmpl_id is not a macOS VM"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Check if already a template
  if grep -q "^template: 1" "/etc/pve/qemu-server/${tmpl_id}.conf" 2>/dev/null; then
    warn "VM $tmpl_id is already a template"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Must be stopped
  local status
  status=$(qm status "$tmpl_id" 2>/dev/null | awk '{print $2}') || true
  if [[ "$status" == "running" ]]; then
    fail "VM must be stopped before converting to template"
    read -rp "  Stop it now? [y/N]: " stop_it
    if [[ "${stop_it:-N}" =~ ^[Yy]$ ]]; then
      info "Stopping VM $tmpl_id..."
      qm shutdown "$tmpl_id" --timeout 60 >>"$LOG_FILE" 2>&1 || qm stop "$tmpl_id" >>"$LOG_FILE" 2>&1
      sleep 3
    else
      read -n 1 -sp "Press any key to return to menu..."
      return
    fi
  fi

  local tmpl_name
  tmpl_name=$(grep "^name:" "/etc/pve/qemu-server/${tmpl_id}.conf" 2>/dev/null | awk '{print $2}')

  echo ""
  echo -e "  ${YELLOW}WARNING: This will convert VM $tmpl_id ($tmpl_name) to a read-only template.${NC}"
  echo "  You will not be able to start it directly, only clone from it."
  echo "  This action can be reversed from the Proxmox UI if needed."
  echo ""
  read -rp "  Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && return

  if ! qm template "$tmpl_id" >>"$LOG_FILE" 2>&1; then
    fail "Failed to convert to template. Check $LOG_FILE"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  ok "VM $tmpl_id ($tmpl_name) converted to template"
  log "Converted VM $tmpl_id ($tmpl_name) to template"
  echo ""
  echo "  To create a new VM from this template:"
  echo "    - Use option 26 (Clone macOS VM) from the menu"
  echo "    - Or: qm clone $tmpl_id <new-id> --name <name> --full --storage <storage>"
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}


# ── List macOS VMs ────────────────────────────────────────────────────────────
list_macos_vms() {
  clear
  echo -e "${BOLD}macOS Virtual Machines${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  find_macos_vms
  if [[ ${#MACOS_VM_IDS[@]} -eq 0 ]]; then
    echo "  No macOS VMs found."
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  printf "  %-6s %-25s %-10s %-6s %-8s %-10s %s\n" "VMID" "NAME" "STATUS" "CORES" "RAM" "DISK" ""
  printf "  %-6s %-25s %-10s %-6s %-8s %-10s %s\n" "────" "────" "──────" "─────" "───" "────" ""

  for vmid in "${MACOS_VM_IDS[@]}"; do
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    local name cores mem status disk_info is_tmpl=""

    name=$(grep "^name:" "$conf" | awk '{print $2}')
    cores=$(grep "^cores:" "$conf" | awk '{print $2}')
    mem=$(grep "^memory:" "$conf" | awk '{print $2}')
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || status="unknown"
    disk_info=$(grep -oP 'virtio0:.*size=\K[0-9]+G' "$conf" 2>/dev/null) || disk_info="?"
    grep -q "^template: 1" "$conf" 2>/dev/null && is_tmpl=" [TPL]"

    local status_color="$RED"
    [[ "$status" == "running" ]] && status_color="$GREEN"
    [[ -n "$is_tmpl" ]] && status_color="$CYAN"

    printf "  %-6s %-25s ${status_color}%-10s${NC} %-6s %-8s %-10s %s\n" \
      "$vmid" "${name:-unnamed}" "${status:-?}${is_tmpl}" "${cores:-?}" "${mem:-?}M" "${disk_info}" ""
  done

  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}

# ── Delete macOS VM ───────────────────────────────────────────────────────────
delete_macos_vm() {
  clear
  echo -e "${BOLD}Delete macOS VM${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  find_macos_vms
  if [[ ${#MACOS_VM_IDS[@]} -eq 0 ]]; then
    echo "  No macOS VMs found."
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  echo "  macOS VMs:"
  for vid in "${MACOS_VM_IDS[@]}"; do
    local vname vstatus
    vname=$(grep "^name:" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null | awk '{print $2}')
    vstatus=$(qm status "$vid" 2>/dev/null | awk '{print $2}') || vstatus="unknown"
    echo "    $vid - ${vname:-unnamed} ($vstatus)"
  done

  echo ""
  read -rp "  Enter VM ID to delete (or 0 to cancel): " del_id
  [[ "$del_id" == "0" || -z "$del_id" ]] && return

  local valid=false
  for v in "${MACOS_VM_IDS[@]}"; do
    [[ "$v" == "$del_id" ]] && valid=true
  done
  if ! $valid; then
    fail "VM $del_id is not a macOS VM or doesn't exist"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  local del_name
  del_name=$(grep "^name:" "/etc/pve/qemu-server/${del_id}.conf" 2>/dev/null | awk '{print $2}')
  echo ""
  echo -e "  ${RED}WARNING: This will permanently delete VM $del_id ($del_name) and all its disks.${NC}"
  read -rp "  Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && return

  local status
  status=$(qm status "$del_id" 2>/dev/null | awk '{print $2}') || true
  if [[ "$status" == "running" ]]; then
    info "Stopping VM $del_id..."
    qm stop "$del_id" >>"$LOG_FILE" 2>&1 || true
    sleep 3
  fi

  if qm destroy "$del_id" --purge >>"$LOG_FILE" 2>&1; then
    ok "VM $del_id ($del_name) deleted"
  else
    fail "Failed to delete VM $del_id"
  fi

  log "Deleted VM $del_id ($del_name)"
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}


# ── Toggle verbose boot ──────────────────────────────────────────────────────
toggle_verbose_boot() {
  clear
  echo -e "${BOLD}Toggle Verbose Boot${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Verbose boot must be toggled from inside the macOS VM."
  echo "  The OpenCore ISO's boot structure cannot be safely"
  echo "  modified from the Proxmox host."
  echo ""
  echo -e "  ${BOLD}To disable verbose boot:${NC}"
  echo ""
  echo "  1. Boot into macOS"
  echo "  2. Open the LongQT-OpenCore volume on the Desktop"
  echo "  3. Run Mount_EFI.command (enter your password)"
  echo "  4. Open EFI/OC/config.plist with ProperTree"
  echo "     (or TextEdit)"
  echo "  5. Find boot-args under:"
  echo "     NVRAM > Add > 7C436110... > boot-args"
  echo "  6. Remove '-v' from the value"
  echo "     (e.g. 'keepsyms=1 -v' becomes 'keepsyms=1')"
  echo "  7. Save and reboot"
  echo ""
  echo -e "  ${BOLD}To enable verbose boot:${NC}"
  echo "  Same steps, but add '-v' to boot-args."
  echo ""
  echo -e "  ${BOLD}Alternative (quick toggle):${NC}"
  echo "  At the OpenCore boot menu, press Space and select"
  echo "  'Toggle SIP' or hold a key to access boot options."
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}

# ── Show VM config ────────────────────────────────────────────────────────────
show_vm_config() {
  clear
  echo -e "${BOLD}VM Configuration${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  read -rp "  Enter VM ID: " vmid
  if [[ ! -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
    fail "VM $vmid not found"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  local conf="/etc/pve/qemu-server/${vmid}.conf"
  local name cores mem cpu machine bios net args status

  name=$(grep "^name:" "$conf" | awk '{print $2}') || true
  cores=$(grep "^cores:" "$conf" | awk '{print $2}') || true
  mem=$(grep "^memory:" "$conf" | awk '{print $2}') || true
  cpu=$(grep "^cpu:" "$conf" | awk '{print $2}') || true
  machine=$(grep "^machine:" "$conf" | awk '{print $2}') || true
  bios=$(grep "^bios:" "$conf" | awk '{print $2}') || true
  net=$(grep "^net0:" "$conf" | sed 's/^net0: //') || true
  args=$(grep "^args:" "$conf" | sed 's/^args: //') || true
  status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}') || status="unknown"

  echo ""
  echo "  VM ID:      $vmid"
  echo "  Name:       ${name:-?}"
  echo "  Status:     ${status}"
  echo "  CPU:        ${cores:-?} cores (${cpu:-?})"
  echo "  RAM:        ${mem:-?} MiB"
  echo "  Machine:    ${machine:-?}"
  echo "  BIOS:       ${bios:-?}"
  echo "  Network:    ${net:-?}"
  echo ""
  echo "  QEMU args:  ${args:-none}"
  echo ""

  echo "  Disks:"
  grep -E "^(virtio|sata|ide|scsi|efidisk)" "$conf" 2>/dev/null | while read -r line; do
    echo "    $line"
  done

  echo ""
  echo "  Snapshots:"
  local snaps
  snaps=$(qm listsnapshot "$vmid" 2>/dev/null | grep -v "^$") || true
  if [[ -n "$snaps" ]]; then
    echo "$snaps" | while read -r line; do
      echo "    $line"
    done
  else
    echo "    (none)"
  fi

  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}

# ── Edit VM config ────────────────────────────────────────────────────────────
edit_vm_config() {
  clear
  echo -e "${BOLD}Edit macOS VM Configuration${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  find_macos_vms
  if [[ ${#MACOS_VM_IDS[@]} -eq 0 ]]; then
    echo "  No macOS VMs found."
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  echo "  macOS VMs:"
  for vid in "${MACOS_VM_IDS[@]}"; do
    local vname vstatus vcores vmem
    local conf="/etc/pve/qemu-server/${vid}.conf"
    vname=$(grep "^name:" "$conf" 2>/dev/null | awk '{print $2}') || true
    vstatus=$(qm status "$vid" 2>/dev/null | awk '{print $2}') || vstatus="unknown"
    vcores=$(grep "^cores:" "$conf" 2>/dev/null | awk '{print $2}') || true
    vmem=$(grep "^memory:" "$conf" 2>/dev/null | awk '{print $2}') || true
    echo "    $vid - ${vname:-unnamed} ($vstatus, ${vcores:-?} cores, ${vmem:-?}M RAM)"
  done

  echo ""
  read -rp "  VM ID to edit (or 0 to cancel): " edit_id
  [[ "$edit_id" == "0" || -z "$edit_id" ]] && return

  local valid=false
  for v in "${MACOS_VM_IDS[@]}"; do
    [[ "$v" == "$edit_id" ]] && valid=true
  done
  if ! $valid; then
    fail "VM $edit_id is not a macOS VM"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  local conf="/etc/pve/qemu-server/${edit_id}.conf"
  local cur_cores cur_mem cur_name
  cur_name=$(grep "^name:" "$conf" 2>/dev/null | awk '{print $2}') || true
  cur_cores=$(grep "^cores:" "$conf" 2>/dev/null | awk '{print $2}') || true
  cur_mem=$(grep "^memory:" "$conf" 2>/dev/null | awk '{print $2}') || true

  echo ""
  echo "  Current config for VM $edit_id ($cur_name):"
  echo "    Cores:  ${cur_cores:-?}"
  echo "    RAM:    ${cur_mem:-?} MiB"
  echo ""
  echo "  Press Enter to keep current value."
  echo ""

  # Cores
  local new_cores
  while true; do
    read -rp "  CPU cores [${cur_cores}]: " new_cores
    new_cores="${new_cores:-$cur_cores}"
    if [[ "$new_cores" =~ ^[0-9]+$ ]] && (( new_cores > 0 && new_cores <= 128 )); then
      break
    fi
    echo "  Must be 1-128."
  done

  # RAM
  local new_mem
  while true; do
    read -rp "  RAM in MiB [${cur_mem}]: " new_mem
    new_mem="${new_mem:-$cur_mem}"
    if [[ "$new_mem" =~ ^[0-9]+$ ]] && (( new_mem >= 2048 )); then
      break
    fi
    echo "  Minimum 2048 MiB."
  done

  # Check if anything changed
  if [[ "$new_cores" == "$cur_cores" && "$new_mem" == "$cur_mem" ]]; then
    info "No changes made"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Warn if running
  local status
  status=$(qm status "$edit_id" 2>/dev/null | awk '{print $2}') || true
  if [[ "$status" == "running" ]]; then
    warn "VM is running. Changes will apply after next restart."
  fi

  # Summary
  echo ""
  echo "  Changes:"
  [[ "$new_cores" != "$cur_cores" ]] && echo "    Cores: $cur_cores -> $new_cores"
  [[ "$new_mem" != "$cur_mem" ]] && echo "    RAM:   $cur_mem -> $new_mem MiB"
  echo ""
  read -rp "  Apply changes? [Y/n]: " confirm
  [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]] && return

  local set_args=""
  [[ "$new_cores" != "$cur_cores" ]] && set_args="$set_args --cores $new_cores"
  [[ "$new_mem" != "$cur_mem" ]] && set_args="$set_args --memory $new_mem"

  if qm set "$edit_id" $set_args >>"$LOG_FILE" 2>&1; then
    ok "VM $edit_id updated"
    log "Updated VM $edit_id: cores=$new_cores, memory=$new_mem"
  else
    fail "Failed to update VM $edit_id"
  fi

  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}


# ── Deploy from Template ──────────────────────────────────────────────────────
deploy_from_template() {
  clear
  echo -e "${BOLD}Deploy macOS VM from Template${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Find templates
  local templates=()
  find_macos_vms
  for vid in "${MACOS_VM_IDS[@]}"; do
    if grep -q "^template: 1" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null; then
      templates+=("$vid")
    fi
  done

  if [[ ${#templates[@]} -eq 0 ]]; then
    echo "  No macOS templates found."
    echo ""
    echo "  To create a template:"
    echo "    1. Install macOS in a VM (options 1-2)"
    echo "    2. Set it up how you like"
    echo "    3. Shut it down"
    echo "    4. Convert to template (option 27)"
    echo ""
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  echo "  Available templates:"
  for tid in "${templates[@]}"; do
    local tname cores mem disk_info
    tname=$(grep "^name:" "/etc/pve/qemu-server/${tid}.conf" 2>/dev/null | awk '{print $2}')
    cores=$(grep "^cores:" "/etc/pve/qemu-server/${tid}.conf" 2>/dev/null | awk '{print $2}')
    mem=$(grep "^memory:" "/etc/pve/qemu-server/${tid}.conf" 2>/dev/null | awk '{print $2}')
    disk_info=$(grep -oP 'virtio0:.*size=\K[0-9]+G' "/etc/pve/qemu-server/${tid}.conf" 2>/dev/null) || disk_info="?"
    echo -e "    ${CYAN}$tid${NC} - ${tname:-unnamed} (${cores:-?} cores, ${mem:-?}M RAM, ${disk_info} disk)"
  done

  echo ""
  local source_id
  if [[ ${#templates[@]} -eq 1 ]]; then
    source_id="${templates[0]}"
    local tname
    tname=$(grep "^name:" "/etc/pve/qemu-server/${source_id}.conf" 2>/dev/null | awk '{print $2}')
    info "Using template: $source_id ($tname)"
  else
    read -rp "  Template ID to deploy from: " source_id
    [[ -z "$source_id" ]] && return
    local valid=false
    for t in "${templates[@]}"; do
      [[ "$t" == "$source_id" ]] && valid=true
    done
    if ! $valid; then
      fail "Not a valid template ID"
      read -n 1 -sp "Press any key to return to menu..."
      return
    fi
  fi

  # New VM ID
  local nextid
  nextid=$(pvesh get /cluster/nextid)
  local new_id
  while true; do
    read -rp "  New VM ID [$nextid]: " new_id
    new_id="${new_id:-$nextid}"
    if [[ "$new_id" =~ ^[0-9]+$ ]] && [[ ! -e "/etc/pve/qemu-server/${new_id}.conf" ]]; then
      break
    fi
    echo "  Invalid or existing VM ID."
  done

  # New name
  local src_name
  src_name=$(grep "^name:" "/etc/pve/qemu-server/${source_id}.conf" 2>/dev/null | awk '{print $2}')
  local default_name="${src_name:-macOS}-$(printf '%03d' "$new_id")"
  local new_name
  while true; do
    read -rp "  VM name [$default_name]: " new_name
    new_name="${new_name:-$default_name}"
    if [[ "$new_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      break
    fi
    echo "  Invalid name."
  done

  # Target storage
  select_storage "images" "Target" || return
  local target_storage="$SELECTED_STORAGE"

  echo ""
  info "Deploying from template $source_id → VM $new_id ($new_name)..."
  info "This creates a full independent copy (may take a minute for large disks)..."

  if ! qm clone "$source_id" "$new_id" --name "$new_name" --full --storage "$target_storage" >>"$LOG_FILE" 2>&1; then
    fail "Deploy failed. Check $LOG_FILE"
    read -n 1 -sp "Press any key to return to menu..."
    return
  fi

  # Tag the new VM
  local new_desc="Deployed from template $source_id ${MACOS_TAG}"
  qm set "$new_id" --description "$new_desc" >>"$LOG_FILE" 2>&1 || true

  ok "VM $new_id ($new_name) deployed from template $source_id"
  log "Deployed VM $new_id ($new_name) from template $source_id"
  echo ""
  echo "  Ready to use — no macOS reinstall needed!"
  echo "  Start it:  qm start $new_id"
  echo ""
  echo "  Note: For iCloud/iMessage, generate a unique SMBIOS serial."
  echo ""
  read -n 1 -sp "Press any key to return to menu..."
}

# ── Main Menu ─────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    clear
    echo ""
    echo "     #############################################"
    echo "     #                                           #"
    echo "     #      macOS VM Manager for Proxmox VE      #"
    echo "     #                                           #"
    echo "     #        Developed by mchiappinam           #"
    echo "     #         github.com/mchiappinam            #"
    echo "     #                                           #"
    echo "     #############################################"
    echo ""
    echo -e "  Version: ${CYAN}${VERSION}${NC}"

    local nextid
    nextid=$(pvesh get /cluster/nextid 2>/dev/null) || nextid="?"
    echo -e "  Next VM ID: ${CYAN}${nextid}${NC}"

    # Check for templates and show quick deploy option prominently
    local has_templates=false
    find_macos_vms
    for vid in "${MACOS_VM_IDS[@]}"; do
      if grep -q "^template: 1" "/etc/pve/qemu-server/${vid}.conf" 2>/dev/null; then
        has_templates=true
        break
      fi
    done

    if $has_templates; then
      echo ""
      echo -e "  ${GREEN}Quick deploy:${NC}"
      echo -e "    ${GREEN}D${NC}  - Deploy new VM from template (no reinstall)"
    fi

    echo ""
    echo "  Create macOS VM (fresh install):"
    for key in $(echo "${!MACOS_VERSIONS[@]}" | tr ' ' '\n' | sort -n); do
      local vname vver
      IFS='|' read -r vname vver _ _ _ <<< "${MACOS_VERSIONS[$key]}"
      echo "    $key - macOS $vname ($vver)"
    done
    echo ""
    echo "  Tools:"
    echo "   20  - Pre-flight system check"
    echo "   21  - List macOS VMs"
    echo "   22  - Delete a macOS VM"
    echo "   23  - Toggle verbose boot"
    echo "   24  - Show VM config"
    echo "   25  - Edit VM config (cores, RAM)"
    echo "   26  - Clone a macOS VM"
    echo "   27  - Convert VM to template"
    echo ""
    echo "    0  - Quit"
    echo ""
    read -rp "  Option: " opt

    case "$opt" in
      [dD])
        if $has_templates; then
          deploy_from_template
        else
          warn "No templates available. Create one first (option 27)."
          sleep 2
        fi
        ;;
      [1-8])
        if [[ -n "${MACOS_VERSIONS[$opt]:-}" ]]; then
          create_macos_vm "$opt"
        else
          warn "Invalid macOS version"
          sleep 1
        fi
        ;;
      20) preflight_check ;;
      21) list_macos_vms ;;
      22) delete_macos_vm ;;
      23) toggle_verbose_boot ;;
      24) show_vm_config ;;
      25) edit_vm_config ;;
      26) clone_macos_vm ;;
      27) convert_to_template ;;
      0|"") exit 0 ;;
      *)  warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Handle CLI flags
case "${1:-}" in
  -h|--help)    show_help ;;
  -v|--version) echo "macOS VM Manager v${VERSION}"; exit 0 ;;
  --preflight)  check_root; init_logging; detect_cpu; preflight_check; exit 0 ;;
esac

check_root
check_dependencies
init_logging
main_menu
