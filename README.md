# proxmox-macos

Interactive macOS VM manager for Proxmox VE. Create, clone, template, and manage macOS virtual machines with a single command.

Uses [LongQT OpenCore ISO](https://github.com/LongQT-sea/OpenCore-ISO) for a clean, vanilla macOS experience — no host-level modifications, no kernel patches, no OVMF hacks.

## ⚠️ Disclaimer

**This project is for educational and research purposes only.**

Apple's macOS Software License Agreement permits virtualization of macOS only on Apple-branded hardware. Running macOS on non-Apple hardware may violate Apple's EULA. Users are solely responsible for ensuring compliance with all applicable licenses and laws.

This project does not include or distribute any Apple software. It automates the creation of virtual machines that can boot macOS using openly available tools.

## Features

- **Interactive TUI** — menu-driven, no commands to memorize
- **Auto-detects your CPU** — picks the correct QEMU model for Intel and AMD
- **Auto-downloads OpenCore ISO** — fetches LongQT OpenCore if not present
- **Downloads macOS recovery** — pulls installer images directly from Apple
- **Template support** — install once, clone instantly for new VMs
- **Pre-flight check** — verifies KVM, CPU features, IOMMU, QEMU version
- **No host modifications** — doesn't touch GRUB, modprobe, or system files
- **Dependency management** — detects and installs missing tools automatically

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mchiappinam/proxmox-macos/main/install.sh)
```

Then run:

```bash
macos-vm
```

## Manual Install

```bash
git clone https://github.com/mchiappinam/proxmox-macos.git /opt/proxmox-macos
chmod +x /opt/proxmox-macos/macos-vm-manager.sh
/opt/proxmox-macos/macos-vm-manager.sh
```

## Requirements

- Proxmox VE 7.x, 8.x, or 9.x
- Intel CPU with VT-x or AMD CPU with SVM
- SSE4.1 support (required for macOS Sierra+)
- AVX2 support (required for macOS Ventura+)
- Internet access (for downloading OpenCore ISO and macOS recovery images)
- Root access on the Proxmox host

## Usage

The main menu:

```
  ┌─────────────────────────────────────────┐
  │       macOS VM Manager v1.1.0           │
  │       for Proxmox VE                    │
  └─────────────────────────────────────────┘

  Quick deploy:
    D  - Deploy new VM from template (no reinstall)

  Create macOS VM (fresh install):
    1 - macOS Sonoma (14)
    2 - macOS Sequoia (15)

  Tools:
    9  - Pre-flight system check
   10  - List macOS VMs
   11  - Delete a macOS VM
   12  - Toggle verbose boot
   13  - Show VM config
   14  - Clone a macOS VM
   15  - Convert VM to template

    0  - Quit
```

### Creating your first VM

1. Run `macos-vm`
2. Pick a macOS version (1 for Sonoma, 2 for Sequoia)
3. Follow the prompts (VM ID, name, storage, cores, RAM, disk)
4. The script downloads the recovery image and creates the VM
5. Start the VM from the Proxmox web UI
6. In the macOS installer: open Disk Utility, erase the VirtIO disk as APFS, then install macOS

### Template workflow (recommended)

After your first successful install:

1. Set up macOS how you like (apps, settings, etc.)
2. Shut down the VM
3. Run `macos-vm` → option **15** to convert to template
4. From now on, press **D** to deploy new VMs instantly — no reinstall needed

### CLI flags

```bash
macos-vm --help        # Show help
macos-vm --version     # Show version
macos-vm --preflight   # Run system check and exit
```

## Supported Hardware

| CPU | QEMU Model | Notes |
|-----|-----------|-------|
| Intel Xeon E5 v3/v4 | Broadwell-noTSX | CPUID model override applied |
| Intel Xeon E5 v2 | Haswell-noTSX | Stepping override applied |
| Intel with AVX-512 | Skylake-Server-v4 | Modern Intel |
| Intel with AVX2 | Skylake-Client-v4 | Haswell+ consumer |
| AMD with AVX2 | Skylake-Client-v4 | Vendor spoofed to GenuineIntel |
| AMD with AVX-512 | Skylake-Server-v4 | Vendor spoofed to GenuineIntel |
| AMD without AVX2 | Nehalem | Limited to macOS Monterey |

## Troubleshooting

### VM won't start — "host doesn't support requested feature"

Your CPU doesn't support the selected QEMU model. The script auto-detects this, but if you've manually changed the CPU type, revert to what the script chose.

### Stuck at Apple logo / black screen

Enable verbose boot (option 12) to see where it freezes. Common fixes:
- Reduce CPU cores to 4 or 8
- Ensure you're using the correct CPU model for your hardware

### "The recovery server could not be contacted"

The VM needs internet access. Make sure your bridge has connectivity and DNS is working.

## Credits

- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) — OpenCore ISO for Proxmox/QEMU
- [Acidanthera](https://github.com/acidanthera) — OpenCore bootloader and kexts
- [Dortania](https://dortania.github.io/) — OpenCore install guides
- [macrecovery](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macrecovery) — macOS recovery downloader

## License

MIT License. See [LICENSE](LICENSE) for details.

Third-party components (OpenCore, kexts) retain their original licenses.
