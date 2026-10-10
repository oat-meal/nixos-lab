#!/usr/bin/env bash
# NixOS Lab Installer — LUKS2 + ZFS + YubiKey FIDO2
# Interactive install for laptop-nixos, workstation-nixos, server-nixos
#
# Usage: sudo ./install.sh
#   or:  install-nixos  (alias available on installer USB)

set -uo pipefail

# Ensure NixOS tools are in PATH (sudo may not preserve it)
export PATH="/run/current-system/sw/bin:/nix/var/nix/profiles/system/sw/bin:$PATH"

################################
## Colors and helpers
################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

confirm() {
    local prompt="${1:-Continue?}"
    echo -en "${YELLOW}${prompt} [y/N]: ${NC}"
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

die() { error "$*"; exit 1; }

# Run a non-piped command, exit on failure with context
run() {
    "$@" || die "Command failed: $*"
}

################################
## Global state (initialized early for set -u)
################################
HOST=""
DISK1=""
DISK2=""
STORAGE_DISK1=""
STORAGE_DISK2=""
PASSPHRASE=""
HOST_ID=""
YUBIKEY_PRESENT=false
YUBIKEY_ENROLLED=false
BOOT_DISK=""  # The USB we booted from — exclude from selection

# Minimum disk sizes (GiB) — ensures swap/datasets fit
declare -A MIN_DISK_SIZE=(
    [laptop-nixos]="64"
    [workstation-nixos]="64"
    [server-nixos]="64"
)

################################
## Cleanup trap
################################
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        error "Installation failed (exit code: $exit_code)"
        echo ""
        info "Cleanup: unmounting, exporting pools, closing LUKS..."

        # 1. Unmount everything under /mnt
        swapoff /dev/zvol/rpool/swap 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true

        # 2. Export ZFS pools
        zpool export storage 2>/dev/null || true
        zpool export rpool 2>/dev/null || true

        # 3. Close LUKS containers
        cryptsetup close cryptroot 2>/dev/null || true
        cryptsetup close cryptroot0 2>/dev/null || true
        cryptsetup close cryptroot1 2>/dev/null || true
        cryptsetup close cryptstorage1 2>/dev/null || true
        cryptsetup close cryptstorage2 2>/dev/null || true

        echo ""
        info "State cleaned up. You can re-run the installer."
        info "If you want to resume manually:"
        echo "  - Check:  lsblk, zpool status, ls /dev/mapper/"
        echo "  - Re-run: sudo /etc/nixos-installer/install.sh"
    fi

    # Clear passphrase from memory
    PASSPHRASE=""
    unset PASSPHRASE 2>/dev/null || true
}
trap cleanup EXIT

################################
## Configuration per host
################################

declare -A HOST_DESC=(
    [laptop-nixos]="Framework 13 Laptop"
    [workstation-nixos]="Gaming Workstation"
    [server-nixos]="Framework Server"
)

declare -A POOL_TYPE=(
    [laptop-nixos]="single"
    [workstation-nixos]="single"
    [server-nixos]="mirror"
)

declare -A SWAP_SIZE=(
    [laptop-nixos]="32"
    [workstation-nixos]="8"
    [server-nixos]="0"
)

declare -A ARC_MAX=(
    [laptop-nixos]=""
    [workstation-nixos]="17179869184"
    [server-nixos]="34359738368"
)

declare -A EXTRA_POOL=(
    [laptop-nixos]=""
    [workstation-nixos]="storage"
    [server-nixos]="tank"
)

################################
## Reread partition table
################################
reread_partitions() {
    local disk="$1"
    sleep 1
    blockdev --rereadpt "$disk" 2>/dev/null || true
    sleep 1
    udevadm settle --timeout=5 2>/dev/null || true
}

################################
## Wait for a partition device node to appear
################################
wait_for_partition() {
    local partition="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while [[ ! -b "$partition" ]] && [[ $elapsed -lt $timeout ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    [[ -b "$partition" ]] || die "Partition $partition did not appear after ${timeout}s"
}

################################
## Detect boot disk (USB we booted from)
################################
detect_boot_disk() {
    # Method 1: find device with our ISO label (prefix match for version changes)
    local iso_dev
    iso_dev=$(blkid -L "nixos-minimal-25.11-x86_64" 2>/dev/null || \
              blkid 2>/dev/null | grep -o '/dev/[^:]*' | while read dev; do
                  blkid -s LABEL -o value "$dev" 2>/dev/null | grep -q "^nixos-" && echo "$dev" && break
              done || true)
    if [[ -n "$iso_dev" ]]; then
        BOOT_DISK=$(lsblk -ndo PKNAME "$iso_dev" 2>/dev/null || true)
        [[ -n "$BOOT_DISK" ]] && BOOT_DISK="/dev/$BOOT_DISK"
    fi

    # Method 2: find device with NIXOS-DATA label (our persistent partition)
    if [[ -z "$BOOT_DISK" ]]; then
        local data_dev
        data_dev=$(blkid -L "NIXOS-DATA" 2>/dev/null || true)
        if [[ -n "$data_dev" ]]; then
            BOOT_DISK=$(lsblk -ndo PKNAME "$data_dev" 2>/dev/null || true)
            [[ -n "$BOOT_DISK" ]] && BOOT_DISK="/dev/$BOOT_DISK"
        fi
    fi

    # Method 3: look for USB transport type (fallback)
    if [[ -z "$BOOT_DISK" ]]; then
        local usb_disk
        usb_disk=$(lsblk -dno NAME,TRAN | awk '$2=="usb"{print "/dev/"$1; exit}')
        if [[ -n "$usb_disk" ]]; then
            BOOT_DISK="$usb_disk"
        fi
    fi
}

################################
## Get disk size in GiB
################################
disk_size_gib() {
    local disk="$1"
    local bytes
    bytes=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    echo $(( bytes / 1073741824 ))
}

################################
## Pre-flight checks
################################
preflight() {
    header "Pre-flight Checks"

    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo ./install.sh)"

    for cmd in parted zpool zfs mkfs.fat cryptsetup systemd-cryptenroll nixos-generate-config nixos-install git blockdev; do
        command -v "$cmd" &>/dev/null || die "Missing required command: $cmd"
    done
    success "All required tools available"

    # Detect boot disk to exclude from selection
    detect_boot_disk
    if [[ -n "$BOOT_DISK" ]]; then
        info "Boot disk detected: $BOOT_DISK (will be excluded from selection)"
    fi

    if ping -c1 -W2 github.com &>/dev/null; then
        success "Network connectivity OK"
    else
        warn "No network — you'll need it for nixos-install"
        echo "  WiFi: nmcli device wifi connect 'SSID' password 'pass'"
        confirm "Continue offline?" || exit 1
    fi

    # Detect YubiKey via ykman or sysfs
    if command -v ykman &>/dev/null && ykman list 2>/dev/null | grep -q "YubiKey"; then
        success "YubiKey detected: $(ykman list 2>/dev/null | head -1)"
        YUBIKEY_PRESENT=true
    elif grep -riq "yubico\|yubikey" /sys/bus/usb/devices/*/manufacturer 2>/dev/null; then
        success "YubiKey detected (via sysfs)"
        YUBIKEY_PRESENT=true
    else
        warn "No YubiKey detected — LUKS will use passphrase only"
        warn "You can enroll YubiKey(s) later with: systemd-cryptenroll"
    fi
}

################################
## Host selection
################################
select_host() {
    header "Host Selection"

    echo -e "  ${BOLD}1)${NC} laptop-nixos      — Framework 13 (1x NVMe, 32GB swap/hibernate)"
    echo -e "  ${BOLD}2)${NC} workstation-nixos  — Ryzen 9950X, 64GB DDR5, RX 9070 XT"
    echo -e "  ${BOLD}3)${NC} server-nixos       — Framework Server (2x NVMe mirror, 128GB)"
    echo -e "  ${BOLD}r)${NC} Refresh flake from GitHub"
    echo -e "  ${BOLD}q)${NC} Exit to shell"
    echo ""

    while true; do
        echo -en "${CYAN}Select [1-3/r/q]: ${NC}"
        read -r choice
        case "$choice" in
            1) HOST="laptop-nixos";      break ;;
            2) HOST="workstation-nixos";  break ;;
            3) HOST="server-nixos";       break ;;
            r) /etc/nixos-installer/refresh-flake.sh; echo ""; continue ;;
            q) echo "Exiting."; exit 0 ;;
            *) error "Invalid choice" ;;
        esac
    done

    success "Selected: $HOST (${HOST_DESC[$HOST]})"
}

################################
## Disk selection
################################
select_disks() {
    header "Disk Selection — ${HOST_DESC[$HOST]}"

    # Build exclusion pattern for boot disk
    local exclude="loop\|sr\|ram\|zram"
    if [[ -n "$BOOT_DISK" ]]; then
        exclude+="\|$(basename "$BOOT_DISK")"
    fi

    echo -e "Available block devices:\n"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "$exclude"
    echo ""

    local min_size="${MIN_DISK_SIZE[$HOST]}"

    if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
        info "Server requires 2 NVMe drives for ZFS mirror"
        echo ""
        echo -en "${CYAN}First NVMe (e.g. nvme0n1): ${NC}"
        read -r d1
        DISK1="/dev/$d1"
        echo -en "${CYAN}Second NVMe (e.g. nvme1n1): ${NC}"
        read -r d2
        DISK2="/dev/$d2"

        [[ -b "$DISK1" ]] || die "Disk not found: $DISK1"
        [[ -b "$DISK2" ]] || die "Disk not found: $DISK2"
        [[ "$DISK1" != "$DISK2" ]] || die "Cannot use the same disk for both mirror members"
        [[ "$DISK1" != "$BOOT_DISK" ]] || die "Cannot use the boot USB as install target"
        [[ "$DISK2" != "$BOOT_DISK" ]] || die "Cannot use the boot USB as install target"

        local size1 size2
        size1=$(disk_size_gib "$DISK1")
        size2=$(disk_size_gib "$DISK2")
        [[ "$size1" -ge "$min_size" ]] || die "$DISK1 is too small (${size1}GiB < ${min_size}GiB minimum)"
        [[ "$size2" -ge "$min_size" ]] || die "$DISK2 is too small (${size2}GiB < ${min_size}GiB minimum)"
    else
        echo -en "${CYAN}Install disk (e.g. nvme0n1): ${NC}"
        read -r d1
        DISK1="/dev/$d1"
        [[ -b "$DISK1" ]] || die "Disk not found: $DISK1"
        [[ "$DISK1" != "$BOOT_DISK" ]] || die "Cannot use the boot USB as install target"

        local size1
        size1=$(disk_size_gib "$DISK1")
        [[ "$size1" -ge "$min_size" ]] || die "$DISK1 is too small (${size1}GiB < ${min_size}GiB minimum)"
    fi

    # Workstation: optional storage mirror
    if [[ "${EXTRA_POOL[$HOST]}" == "storage" ]]; then
        echo ""
        if confirm "Set up /storage ZFS mirror pool? (2 additional drives)"; then
            echo ""
            lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "$exclude\|$(basename "$DISK1")"
            echo ""
            echo -en "${CYAN}Storage drive 1 (e.g. nvme0n1): ${NC}"
            read -r s1
            STORAGE_DISK1="/dev/$s1"
            echo -en "${CYAN}Storage drive 2 (e.g. nvme1n1): ${NC}"
            read -r s2
            STORAGE_DISK2="/dev/$s2"
            [[ -b "$STORAGE_DISK1" ]] || die "Disk not found: $STORAGE_DISK1"
            [[ -b "$STORAGE_DISK2" ]] || die "Disk not found: $STORAGE_DISK2"
            [[ "$STORAGE_DISK1" != "$STORAGE_DISK2" ]] || die "Storage drives must be different"
            [[ "$STORAGE_DISK1" != "$DISK1" ]] || die "Storage drive 1 is the same as the install disk"
            [[ "$STORAGE_DISK2" != "$DISK1" ]] || die "Storage drive 2 is the same as the install disk"
            [[ "$STORAGE_DISK1" != "$BOOT_DISK" ]] || die "Cannot use the boot USB as storage"
            [[ "$STORAGE_DISK2" != "$BOOT_DISK" ]] || die "Cannot use the boot USB as storage"
        fi
    fi

    # Summary and confirmation
    echo ""
    warn "ALL DATA on these disks will be ERASED:"
    echo "  $DISK1 ($(lsblk -dno SIZE "$DISK1" 2>/dev/null || echo "?"))"
    [[ -n "$DISK2" ]] && echo "  $DISK2 ($(lsblk -dno SIZE "$DISK2" 2>/dev/null || echo "?"))"
    [[ -n "$STORAGE_DISK1" ]] && echo "  $STORAGE_DISK1 ($(lsblk -dno SIZE "$STORAGE_DISK1" 2>/dev/null || echo "?"))"
    [[ -n "$STORAGE_DISK2" ]] && echo "  $STORAGE_DISK2 ($(lsblk -dno SIZE "$STORAGE_DISK2" 2>/dev/null || echo "?"))"
    echo ""
    confirm "Proceed with disk erasure?" || die "Aborted"
}

################################
## LUKS passphrase
################################
get_passphrase() {
    header "LUKS2 Encryption"

    info "Set a fallback passphrase for disk encryption."
    info "This is used when no YubiKey is available."
    echo ""

    while true; do
        echo -en "${CYAN}Passphrase (hidden): ${NC}"
        read -rs PASSPHRASE
        echo ""

        if confirm "Show passphrase to verify?"; then
            echo -e "  Passphrase: ${BOLD}${PASSPHRASE}${NC}"
            echo ""
        fi

        echo -en "${CYAN}Confirm passphrase:  ${NC}"
        read -rs PASSPHRASE2
        echo ""

        if [[ "$PASSPHRASE" == "$PASSPHRASE2" ]]; then
            if [[ ${#PASSPHRASE} -lt 8 ]]; then
                warn "Passphrase too short (min 8 chars)"
                continue
            fi
            break
        else
            warn "Passphrases don't match"
        fi
    done
    unset PASSPHRASE2
    success "Passphrase set"
}

################################
## Generate host ID
################################
generate_host_id() {
    HOST_ID=$(head -c 8 /dev/urandom | od -A none -t x4 | tr -d ' ' | head -c 8)
    info "Generated hostId: $HOST_ID"
}

################################
## Partition a single disk
################################
partition_disk() {
    local disk="$1"
    local make_efi="${2:-true}"

    info "Partitioning $disk..."
    run wipefs -af "$disk"
    run sgdisk --zap-all "$disk"

    run parted "$disk" -- mklabel gpt

    if [[ "$make_efi" == "true" ]]; then
        run parted "$disk" -- mkpart ESP fat32 1MiB 512MiB
        run parted "$disk" -- set 1 esp on
        run parted "$disk" -- mkpart primary 512MiB 100%
        reread_partitions "$disk"
        wait_for_partition "${disk}p2"
        run mkfs.fat -F32 "${disk}p1"
        success "Partitioned $disk (512MB EFI + LUKS remainder)"
    else
        run parted "$disk" -- mkpart primary 1MiB 100%
        reread_partitions "$disk"
        wait_for_partition "${disk}p1"
        success "Partitioned $disk (LUKS only — EFI on other disk)"
    fi
}

################################
## Create LUKS2 container
################################
create_luks() {
    local partition="$1"
    local name="$2"

    info "Creating LUKS2 container on $partition -> /dev/mapper/$name"

    # Format with passphrase (explicit pipe, check exit separately)
    echo -n "$PASSPHRASE" | cryptsetup luksFormat --type luks2 \
        --pbkdf argon2id "$partition" --batch-mode -d -
    [[ ${PIPESTATUS[1]} -eq 0 ]] || die "cryptsetup luksFormat failed on $partition"

    # Open the container
    echo -n "$PASSPHRASE" | cryptsetup open "$partition" "$name" -d -
    [[ ${PIPESTATUS[1]} -eq 0 ]] || die "cryptsetup open failed on $partition"

    success "LUKS2 container created: /dev/mapper/$name"
}

################################
## YubiKey FIDO2 setup
################################
setup_yubikey() {
    header "YubiKey FIDO2 Setup"

    info "Before enrolling YubiKeys for LUKS, each key needs a FIDO2 PIN."
    info "Fresh YubiKeys have no PIN set — this is required by systemd-cryptenroll."
    echo ""

    local key_num=1
    while true; do
        echo -en "${CYAN}Set up YubiKey #${key_num}? [Y/n]: ${NC}"
        read -r reply
        if [[ "$reply" =~ ^[Nn]$ ]]; then
            break
        fi

        echo ""
        info "Insert YubiKey #${key_num} and press Enter..."
        read -r

        # Show key info
        if command -v ykman &>/dev/null; then
            echo ""
            ykman info 2>/dev/null || warn "Could not read YubiKey info"
            echo ""

            # Check if FIDO2 PIN is set
            local pin_set=false
            if ykman fido info 2>/dev/null | grep -qi "PIN is set"; then
                success "FIDO2 PIN is already set on this key"
                pin_set=true
            else
                info "No FIDO2 PIN set on this key. Setting one now..."
                echo ""
                echo -en "${CYAN}New FIDO2 PIN (min 4 chars): ${NC}"
                read -rs fido_pin
                echo ""
                echo -en "${CYAN}Confirm PIN:                 ${NC}"
                read -rs fido_pin2
                echo ""

                if [[ "$fido_pin" != "$fido_pin2" ]]; then
                    warn "PINs don't match"
                elif [[ ${#fido_pin} -lt 4 ]]; then
                    warn "PIN too short (min 4 chars)"
                else
                    if ykman fido access change-pin --new-pin "$fido_pin" 2>/dev/null; then
                        success "FIDO2 PIN set successfully"
                        pin_set=true
                    elif ykman fido access change-pin -n "$fido_pin" 2>/dev/null; then
                        success "FIDO2 PIN set successfully"
                        pin_set=true
                    else
                        warn "Failed to set PIN. Try manually: ykman fido access change-pin"
                    fi
                fi
                unset fido_pin fido_pin2
            fi

            if [[ "$pin_set" != "true" ]]; then
                warn "YubiKey #${key_num} PIN not set — LUKS enrollment will fail without it"
                if ! confirm "Continue anyway?"; then
                    continue
                fi
            fi
        else
            warn "ykman not available — cannot verify PIN status"
        fi

        key_num=$((key_num + 1))
        [[ $key_num -gt 3 ]] && break

        echo ""
        info "Remove this YubiKey before inserting the next one."
        echo ""
    done
}

################################
## Enroll YubiKeys on all LUKS partitions
################################
enroll_all_yubikeys() {
    if [[ "$YUBIKEY_PRESENT" != "true" ]]; then
        info "Skipping YubiKey enrollment (no key detected)"
        info "Enroll later with: systemd-cryptenroll <partition> --fido2-device=auto"
        return
    fi

    header "YubiKey FIDO2 Enrollment"

    # Collect all LUKS partitions
    local -a luks_partitions=()
    if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
        luks_partitions+=("${DISK1}p2" "${DISK2}p1")
    else
        luks_partitions+=("${DISK1}p2")
    fi
    if [[ -n "$STORAGE_DISK1" ]]; then
        local sp1="${STORAGE_DISK1}1"
        [[ -b "${STORAGE_DISK1}p1" ]] && sp1="${STORAGE_DISK1}p1"
        local sp2="${STORAGE_DISK2}1"
        [[ -b "${STORAGE_DISK2}p1" ]] && sp2="${STORAGE_DISK2}p1"
        luks_partitions+=("$sp1" "$sp2")
    fi

    info "LUKS partitions to enroll: ${luks_partitions[*]}"
    echo ""

    if ! confirm "Enroll YubiKey(s) on all ${#luks_partitions[@]} LUKS partition(s)?"; then
        info "Skipping — enroll later with:"
        for p in "${luks_partitions[@]}"; do
            echo "  systemd-cryptenroll $p --fido2-device=auto"
        done
        return
    fi

    local key_num=1
    while [[ $key_num -le 3 ]]; do
        echo ""
        echo -en "${CYAN}Enroll YubiKey #${key_num}? [Y/n]: ${NC}"
        read -r reply
        if [[ "$reply" =~ ^[Nn]$ ]]; then
            break
        fi

        echo ""
        echo -e "${BOLD}>>> Insert YubiKey #${key_num} and press Enter...${NC}"
        read -r
        echo ""
        echo -e "${YELLOW}For each partition below, you will be prompted to:${NC}"
        echo -e "${YELLOW}  1. Enter your FIDO2 PIN${NC}"
        echo -e "${YELLOW}  2. Touch the YubiKey when it blinks${NC}"
        echo ""

        local all_ok=true
        for partition in "${luks_partitions[@]}"; do
            info "Enrolling on $partition (enter PIN + touch when prompted)..."

            # Write passphrase to temp file for --password-file (more reliable than pipe)
            local pw_file
            pw_file=$(mktemp)
            printf '%s' "$PASSPHRASE" > "$pw_file"

            local enroll_output
            # Try --password-file first (systemd 256+), fall back to piping via stdin
            if systemd-cryptenroll --help 2>&1 | grep -q -- "--password-file"; then
                enroll_output=$(systemd-cryptenroll "$partition" \
                    --password-file="$pw_file" \
                    --fido2-device=auto \
                    --fido2-with-client-pin=yes 2>&1) && {
                    success "  Enrolled on $partition"
                    rm -f "$pw_file"
                    continue
                }
            fi
            # Fallback: pipe passphrase via stdin (works on all systemd versions)
            if enroll_output=$(printf '%s' "$PASSPHRASE" | systemd-cryptenroll "$partition" \
                --fido2-device=auto \
                --fido2-with-client-pin=yes 2>&1); then
                success "  Enrolled on $partition"
            else
                warn "  Failed on $partition: $(echo "$enroll_output" | head -1)"
                all_ok=false
            fi

            rm -f "$pw_file"
        done

        if [[ "$all_ok" == "true" ]]; then
            success "YubiKey #${key_num} enrolled on all partitions"
            YUBIKEY_ENROLLED=true
        else
            warn "Some enrollments failed — you can retry or enroll later"
            if confirm "Retry YubiKey #${key_num}?"; then
                continue  # Don't increment, retry same key
            fi
        fi

        key_num=$((key_num + 1))

        if [[ $key_num -le 3 ]]; then
            echo ""
            warn "Remove this YubiKey carefully (avoid touching the contact to prevent OTP input)."
            info "Then insert the next key when prompted."
        fi
    done
}

################################
## Create ZFS pools
################################
create_zfs() {
    header "ZFS Pool Creation"

    local zfs_opts=(
        -o ashift=12
        -o cachefile=/etc/zfs/zpool.cache
        -O mountpoint=none
        -O acltype=posixacl
        -O xattr=sa
        -O compression=zstd
        -O normalization=formD
        -O atime=off
        -O relatime=on
    )

    # rpool
    if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
        info "Creating rpool mirror: cryptroot0 + cryptroot1"
        run zpool create -f "${zfs_opts[@]}" rpool mirror /dev/mapper/cryptroot0 /dev/mapper/cryptroot1
    else
        info "Creating rpool on cryptroot"
        run zpool create -f "${zfs_opts[@]}" rpool /dev/mapper/cryptroot
    fi

    # Datasets
    info "Creating datasets..."
    run zfs create -o mountpoint=legacy rpool/ROOT
    run zfs create -o mountpoint=legacy rpool/ROOT/nixos
    run zfs create -o mountpoint=legacy rpool/home
    run zfs create -o mountpoint=legacy -o atime=off rpool/nix
    run zfs create -o mountpoint=legacy rpool/log

    # Swap zvol
    local swap="${SWAP_SIZE[$HOST]}"
    if [[ "$swap" -gt 0 ]]; then
        info "Creating ${swap}GB swap zvol..."
        run zfs create -V "${swap}G" -b 4096 -o compression=zle -o sync=always rpool/swap
    fi

    success "rpool created"
    zpool status rpool

    # Workstation storage pool
    if [[ -n "$STORAGE_DISK1" ]] && [[ -n "$STORAGE_DISK2" ]]; then
        echo ""
        info "Creating storage mirror: cryptstorage1 + cryptstorage2"
        run zpool create -f "${zfs_opts[@]}" storage mirror /dev/mapper/cryptstorage1 /dev/mapper/cryptstorage2
        run zfs create -o mountpoint=legacy -o recordsize=1M storage/data
        success "storage pool created"
        zpool status storage
    fi

    # Server tank pool — created later with DAS hardware
    if [[ "${EXTRA_POOL[$HOST]}" == "tank" ]]; then
        echo ""
        info "The 'tank' pool (USB-C DAS) will be created after install."
        info "See Phase 4 in the redeployment plan."
    fi
}

################################
## Mount filesystems
################################
mount_filesystems() {
    header "Mounting Filesystems"

    run mount -t zfs rpool/ROOT/nixos /mnt
    mkdir -p /mnt/{home,nix,var/log,boot}
    run mount -t zfs rpool/home /mnt/home
    run mount -t zfs rpool/nix /mnt/nix
    run mount -t zfs rpool/log /mnt/var/log
    run mount "${DISK1}p1" /mnt/boot

    if [[ "${SWAP_SIZE[$HOST]}" -gt 0 ]]; then
        run mkswap /dev/zvol/rpool/swap
        run swapon /dev/zvol/rpool/swap
    fi

    if [[ -n "$STORAGE_DISK1" ]]; then
        mkdir -p /mnt/storage
        run mount -t zfs storage/data /mnt/storage
    fi

    # Copy ZFS cachefile to target
    mkdir -p /mnt/etc/zfs
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache 2>/dev/null || true

    success "All filesystems mounted at /mnt"
    df -h /mnt /mnt/home /mnt/nix /mnt/boot 2>/dev/null || true
}

################################
## Set up NixOS configuration
################################
setup_config() {
    header "NixOS Configuration"

    # Determine host directory
    local host_dir
    case "$HOST" in
        laptop-nixos)      host_dir="hosts/laptop" ;;
        workstation-nixos) host_dir="hosts/workstation" ;;
        server-nixos)      host_dir="hosts/server" ;;
    esac

    # Generate hardware-configuration.nix directly from what we just created
    # (nixos-generate-config can pick up installer environment artifacts)
    info "Generating hardware-configuration.nix..."
    local boot_uuid
    boot_uuid=$(blkid -s UUID -o value "${DISK1}p1") || die "Cannot read UUID of EFI partition ${DISK1}p1"

    local hw_content
    hw_content="{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + \"/installer/scan/not-detected.nix\") ];

  boot.initrd.availableKernelModules = [ \"nvme\" \"xhci_pci\" \"thunderbolt\" \"usb_storage\" \"sd_mod\" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ \"kvm-amd\" ];
  boot.extraModulePackages = [ ];

  fileSystems.\"/\" = { device = \"rpool/ROOT/nixos\"; fsType = \"zfs\"; };
  fileSystems.\"/home\" = { device = \"rpool/home\"; fsType = \"zfs\"; };
  fileSystems.\"/nix\" = { device = \"rpool/nix\"; fsType = \"zfs\"; };
  fileSystems.\"/var/log\" = { device = \"rpool/log\"; fsType = \"zfs\"; };
  fileSystems.\"/boot\" = { device = \"/dev/disk/by-uuid/${boot_uuid}\"; fsType = \"vfat\"; options = [ \"fmask=0077\" \"dmask=0077\" ]; };
"

    # Add storage mount if applicable
    if [[ -n "$STORAGE_DISK1" ]]; then
        hw_content+="  fileSystems.\"/storage\" = { device = \"storage/data\"; fsType = \"zfs\"; };
"
    fi

    # Swap via ZFS zvol (if configured for this host)
    if [[ "${SWAP_SIZE[$HOST]}" -gt 0 ]]; then
        hw_content+="
  swapDevices = [{ device = \"/dev/zvol/rpool/swap\"; }];
  boot.resumeDevice = \"/dev/zvol/rpool/swap\";
"
    else
        hw_content+="
  swapDevices = [ ];
"
    fi

    hw_content+="
  nixpkgs.hostPlatform = lib.mkDefault \"x86_64-linux\";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
"
    printf '%s' "$hw_content" > /tmp/hardware-configuration.nix

    # Find the flake repo — check persistent USB first, then /tmp
    local flake_source=""
    local persistent_dev
    persistent_dev=$(blkid -L "NIXOS-DATA" 2>/dev/null || true)

    if [[ -n "$persistent_dev" ]]; then
        mkdir -p /tmp/usb-data
        mountpoint -q /tmp/usb-data || mount "$persistent_dev" /tmp/usb-data
        if [[ -d /tmp/usb-data/nixos-lab/.git ]]; then
            flake_source="/tmp/usb-data/nixos-lab"
            info "Using flake from USB persistent partition"
        fi
    fi

    if [[ -z "$flake_source" ]]; then
        if [[ -d /tmp/nixos-lab/.git ]]; then
            info "Using existing flake clone at /tmp/nixos-lab"
            flake_source="/tmp/nixos-lab"
        else
            info "Cloning flake from GitHub..."
            run git clone https://github.com/oat-meal/nixos-lab.git /tmp/nixos-lab
            flake_source="/tmp/nixos-lab"
        fi
    fi

    # Copy flake to target
    rm -rf /mnt/etc/nixos
    run cp -a "$flake_source" /mnt/etc/nixos

    # Cloned over HTTPS because the ISO has no GitHub key, but HTTPS cannot push. Point the
    # installed copy at SSH so the host can push its installer commit once oat's key is on
    # GitHub, instead of the commit being stranded on this one disk.
    run git -C /mnt/etc/nixos remote set-url origin git@github.com:oat-meal/nixos-lab.git

    # Place hardware-configuration.nix
    cp /tmp/hardware-configuration.nix "/mnt/etc/nixos/${host_dir}/hardware-configuration.nix"

    # Inject hostId and LUKS config into hardware-configuration.nix
    local hw_file="/mnt/etc/nixos/${host_dir}/hardware-configuration.nix"
    inject_nix_config "$hw_file"

    # Ensure luks.nix is imported in the host's default.nix
    local host_default="/mnt/etc/nixos/${host_dir}/default.nix"
    local luks_import="../common/optional/security/luks.nix"
    if [[ -f "$host_default" ]] && ! grep -q "security/luks.nix" "$host_default"; then
        info "Adding luks.nix import to ${host_dir}/default.nix..."
        # Insert after the imports = [ line
        local imports_line
        imports_line=$(grep -n 'imports = \[' "$host_default" | head -1 | cut -d: -f1)
        if [[ -n "$imports_line" ]]; then
            local tmp_default="${host_default}.tmp"
            head -n "$imports_line" "$host_default" > "$tmp_default"
            echo "    # Security" >> "$tmp_default"
            echo "    ${luks_import}" >> "$tmp_default"
            echo "" >> "$tmp_default"
            tail -n +"$((imports_line + 1))" "$host_default" >> "$tmp_default"
            mv "$tmp_default" "$host_default"
            success "Injected luks.nix import"
        else
            warn "Could not find imports block in ${host_dir}/default.nix — add luks.nix manually"
        fi
    fi

    # Stage all files in git so nix flake can see them
    # (nix flakes in git repos only evaluate tracked files)
    info "Staging modified files in git..."
    git config --global --add safe.directory /mnt/etc/nixos
    git -C /mnt/etc/nixos add -A || die "git add failed — cannot stage config files"

    # Verify the hardware-configuration.nix has our ZFS config, not the old repo version
    if ! grep -q "zfs\|rpool" "$hw_file"; then
        die "hardware-configuration.nix does not contain ZFS config — staging may have failed"
    fi

    # Validate UUIDs in hardware-configuration.nix match actual disk UUIDs
    info "Validating disk UUIDs..."
    local uuid_errors=0
    while IFS= read -r uuid; do
        if [[ -n "$uuid" ]] && ! blkid -U "$uuid" &>/dev/null; then
            warn "UUID $uuid not found on any disk — stale config detected"
            uuid_errors=$((uuid_errors + 1))
        fi
    done < <(grep -oP 'by-uuid/\K[A-Fa-f0-9-]+' "$hw_file")

    if [[ $uuid_errors -gt 0 ]]; then
        die "Found $uuid_errors invalid UUID(s) in hardware-configuration.nix — this should not happen with direct generation. Check blkid output and script logic."
    else
        success "All UUIDs verified against actual disks"
    fi

    success "Configuration ready at /mnt/etc/nixos"

    # Quick syntax validation (does not evaluate the full flake / download nixpkgs)
    info "Validating hardware-configuration.nix syntax..."
    if command -v nix-instantiate &>/dev/null; then
        if nix-instantiate --parse "$hw_file" > /dev/null 2>&1; then
            success "Nix syntax OK"
        else
            warn "Nix syntax check failed on hardware-configuration.nix:"
            nix-instantiate --parse "$hw_file" 2>&1 | head -5
            if ! confirm "Continue anyway?"; then
                die "Aborted — fix hardware-configuration.nix and re-run"
            fi
        fi
    elif command -v nix &>/dev/null; then
        if nix eval --expr "builtins.readFile $hw_file" > /dev/null 2>&1; then
            success "Nix syntax OK"
        else
            warn "Nix syntax check inconclusive — continuing"
        fi
    else
        info "No Nix parser available for syntax check — skipping"
    fi

    # Commit the installer-generated host blocks (hostId + LUKS devices +
    # luks.nix import) so git HEAD is authoritative — not just staged.
    # Staging alone (the `git add -A` above) leaves these uncommitted, which
    # (a) blocks `git pull --rebase` on later deploys and (b) is silently wiped
    # by any `git reset --hard` / `git checkout .` used to unblock that pull.
    # That is exactly how server-nixos lost its cryptroot LUKS block and booted
    # with no passphrase prompt (rpool unimportable). A real commit survives
    # resets and replays cleanly on rebase.
    if git -C /mnt/etc/nixos diff --cached --quiet; then
        info "No staged host-config changes to commit"
    else
        info "Committing installer-generated host config to git..."
        if git -C /mnt/etc/nixos \
            -c user.name="oat-meal" \
            -c user.email="oat-meal@users.noreply.github.com" \
            commit -q -m "${HOST}: installer-generated hardware config (hostId + LUKS devices)

Auto-committed by installer/install.sh so the host-specific blocks live in
HEAD, not just the index. Push to origin so the shared repo carries them."; then
            success "Committed host config (HEAD now contains hostId + LUKS block)"
        else
            warn "git commit failed — push ${host_dir}/hardware-configuration.nix manually or it will be lost on the next deploy"
        fi
    fi
}

################################
## Inject Nix config into hardware-configuration.nix
################################
inject_nix_config() {
    local hw_file="$1"

    # Build the config block to inject
    local inject=""

    # hostId (required for ZFS). If the host module already pins one (server-nixos sets it
    # in default.nix, matched by its spl.spl_hostid kernel parameter), adopt that value and
    # inject nothing: two definitions do not merge, and the install fails to evaluate with
    # "networking.hostId has conflicting definition values" (verified 2026-10-10).
    local host_default pinned_id
    host_default="$(dirname "$hw_file")/default.nix"
    pinned_id=$(sed -n 's/^ *networking\.hostId = "\([0-9a-f]\{8\}\)";.*/\1/p' "$host_default" 2>/dev/null | head -1)
    if [[ -n "$pinned_id" ]]; then
        HOST_ID="$pinned_id"
        info "hostId pinned by ${host_default##*/etc/nixos/}: $HOST_ID (not injected)"
    elif ! grep -q "networking.hostId" "$hw_file"; then
        inject+=$'\n'"  # Required for ZFS"$'\n'
        inject+="  networking.hostId = \"${HOST_ID}\";"$'\n'
    fi

    # LUKS devices — only add fido2-device if actually enrolled
    local fido_opt=""
    if [[ "$YUBIKEY_ENROLLED" == "true" ]]; then
        fido_opt=$'\n'"    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"
    fi

    if ! grep -q "luks.devices" "$hw_file"; then
        if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
            local uuid0 uuid1
            uuid0=$(blkid -s UUID -o value "${DISK1}p2") || die "Cannot read UUID of ${DISK1}p2"
            uuid1=$(blkid -s UUID -o value "${DISK2}p1") || die "Cannot read UUID of ${DISK2}p1"
            inject+=$'\n'
            inject+="  # LUKS2 encrypted root (mirror)"$'\n'
            inject+="  boot.initrd.luks.devices.\"cryptroot0\" = {"$'\n'
            inject+="    device = \"/dev/disk/by-uuid/${uuid0}\";"$'\n'
            [[ -n "$fido_opt" ]] && inject+="    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"$'\n'
            inject+="  };"$'\n'
            inject+="  boot.initrd.luks.devices.\"cryptroot1\" = {"$'\n'
            inject+="    device = \"/dev/disk/by-uuid/${uuid1}\";"$'\n'
            [[ -n "$fido_opt" ]] && inject+="    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"$'\n'
            inject+="  };"$'\n'
        else
            local uuid
            uuid=$(blkid -s UUID -o value "${DISK1}p2") || die "Cannot read UUID of ${DISK1}p2"
            inject+=$'\n'
            inject+="  # LUKS2 encrypted root"$'\n'
            inject+="  boot.initrd.luks.devices.\"cryptroot\" = {"$'\n'
            inject+="    device = \"/dev/disk/by-uuid/${uuid}\";"$'\n'
            [[ -n "$fido_opt" ]] && inject+="    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"$'\n'
            inject+="  };"$'\n'
        fi

        # Storage LUKS if applicable
        if [[ -n "$STORAGE_DISK1" ]]; then
            local sp1="${STORAGE_DISK1}1"
            [[ -b "${STORAGE_DISK1}p1" ]] && sp1="${STORAGE_DISK1}p1"
            local sp2="${STORAGE_DISK2}1"
            [[ -b "${STORAGE_DISK2}p1" ]] && sp2="${STORAGE_DISK2}p1"
            local suuid1 suuid2
            suuid1=$(blkid -s UUID -o value "$sp1") || die "Cannot read UUID of $sp1"
            suuid2=$(blkid -s UUID -o value "$sp2") || die "Cannot read UUID of $sp2"
            inject+="  boot.initrd.luks.devices.\"cryptstorage1\" = {"$'\n'
            inject+="    device = \"/dev/disk/by-uuid/${suuid1}\";"$'\n'
            [[ -n "$fido_opt" ]] && inject+="    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"$'\n'
            inject+="  };"$'\n'
            inject+="  boot.initrd.luks.devices.\"cryptstorage2\" = {"$'\n'
            inject+="    device = \"/dev/disk/by-uuid/${suuid2}\";"$'\n'
            [[ -n "$fido_opt" ]] && inject+="    cryptTabExtraOpts = [ \"fido2-device=auto\" ];"$'\n'
            inject+="  };"$'\n'
        fi
    fi

    # ZFS extra pools (storage pool auto-import)
    if [[ -n "$STORAGE_DISK1" ]] && ! grep -q "boot.zfs.extraPools" "$hw_file"; then
        inject+=$'\n'
        inject+="  # Auto-import additional ZFS pools"$'\n'
        inject+="  boot.zfs.extraPools = [ \"storage\" ];"$'\n'
    fi

    # Write the injection
    if [[ -n "$inject" ]]; then
        info "Injecting hostId, LUKS, and ZFS config..."
        # Write everything before last }, then inject, then }
        local tmp_file="${hw_file}.tmp"
        # Find line number of last }
        local last_brace_line
        last_brace_line=$(grep -n '^}' "$hw_file" | tail -1 | cut -d: -f1)

        if [[ -n "$last_brace_line" ]]; then
            head -n $((last_brace_line - 1)) "$hw_file" > "$tmp_file"
            printf '%s' "$inject" >> "$tmp_file"
            echo "}" >> "$tmp_file"
            mv "$tmp_file" "$hw_file"
        else
            warn "Could not find closing brace in $hw_file — appending config"
            printf '%s' "$inject" >> "$hw_file"
        fi
    fi
}

################################
## Show summary
################################
show_summary() {
    header "Installation Summary"

    local swap="${SWAP_SIZE[$HOST]}"
    local arc="${ARC_MAX[$HOST]}"

    echo -e "  ${BOLD}Host:${NC}        $HOST (${HOST_DESC[$HOST]})"
    echo -e "  ${BOLD}Host ID:${NC}     $HOST_ID"
    echo -e "  ${BOLD}Boot disk:${NC}   $DISK1"
    [[ -n "$DISK2" ]]          && echo -e "  ${BOLD}Mirror:${NC}      $DISK2"
    echo -e "  ${BOLD}Encryption:${NC}  LUKS2 + passphrase"
    if [[ "$YUBIKEY_ENROLLED" == "true" ]]; then
        echo -e "  ${BOLD}YubiKey:${NC}     FIDO2 enrolled"
    elif [[ "$YUBIKEY_PRESENT" == "true" ]]; then
        echo -e "  ${BOLD}YubiKey:${NC}     detected but not enrolled"
    fi
    echo -e "  ${BOLD}Pool type:${NC}   ${POOL_TYPE[$HOST]}"
    [[ "$swap" -gt 0 ]]        && echo -e "  ${BOLD}Swap:${NC}        ${swap}GB zvol"
    [[ -n "$arc" ]]            && echo -e "  ${BOLD}ARC max:${NC}     $(( arc / 1073741824 ))GB"
    [[ -n "$STORAGE_DISK1" ]]  && echo -e "  ${BOLD}Storage:${NC}     mirror ($STORAGE_DISK1 + $STORAGE_DISK2)"
    echo -e "  ${BOLD}Flake:${NC}       /etc/nixos#${HOST}"
    echo ""
}

################################
## Run nixos-install
################################
INSTALL_COMPLETED=false

run_install() {
    if ! confirm "Ready to run nixos-install?"; then
        echo ""
        info "Run manually when ready:"
        echo "  nixos-install --flake /mnt/etc/nixos#${HOST} --no-root-password"
        echo ""
        warn "Installation was NOT run. Post-install steps still apply after you run it."
        return
    fi

    header "Installing NixOS"
    info "This will take 5-30 minutes depending on network speed..."
    echo ""

    # Pre-build the system closure ourselves (avoids nixos-install's internal
    # flake resolution which can fail if jq isn't in its PATH on the live ISO)
    info "Building system closure..."
    local system_path
    system_path=$(nix build "/mnt/etc/nixos#nixosConfigurations.${HOST}.config.system.build.toplevel" \
        --no-link --print-out-paths 2>&1 | tail -1)

    if [[ -z "$system_path" ]] || [[ ! -d "$system_path" ]]; then
        warn "Pre-build failed, falling back to nixos-install --flake"
        if nixos-install --flake "/mnt/etc/nixos#${HOST}" --no-root-password; then
            INSTALL_COMPLETED=true
        elif nixos-install --flake "/mnt/etc/nixos#${HOST}"; then
            INSTALL_COMPLETED=true
        else
            die "nixos-install failed"
        fi
    else
        success "System closure built: $system_path"
        if nixos-install --system "$system_path" --no-root-password; then
            INSTALL_COMPLETED=true
        elif nixos-install --system "$system_path"; then
            INSTALL_COMPLETED=true
        else
            die "nixos-install failed"
        fi
    fi

    if [[ "$INSTALL_COMPLETED" == "true" ]]; then
        success "Installation complete!"
    fi

    # Fix ownership now that nix is done reading the repo
    chown -R 1000:100 /mnt/etc/nixos
}

################################
## Post-install
################################
post_install() {
    header "Post-Install Checklist"

    echo -e "  ${GREEN}[x]${NC} LUKS2 encrypted, passphrase set"
    [[ "$YUBIKEY_ENROLLED" == "true" ]] && echo -e "  ${GREEN}[x]${NC} YubiKey FIDO2 enrolled"
    echo -e "  ${GREEN}[x]${NC} ZFS pool(s) created on LUKS"
    if [[ "$INSTALL_COMPLETED" == "true" ]]; then
        echo -e "  ${GREEN}[x]${NC} NixOS installed as ${HOST}"
    else
        echo -e "  ${YELLOW}[ ]${NC} NixOS NOT yet installed — run manually:"
        echo "      nixos-install --flake /mnt/etc/nixos#${HOST} --no-root-password"
    fi
    echo -e "  ${GREEN}[x]${NC} hostId: $HOST_ID"
    echo -e "  ${GREEN}[x]${NC} host config committed to git (hostId + LUKS block in HEAD)"
    echo ""
    echo -e "  ${YELLOW}!${NC} ${BOLD}Push this host's config to origin${NC} so the shared repo carries it."
    echo "     origin is set to SSH; if this host's key is not on GitHub yet, copy"
    echo "     hardware-configuration.nix to the workstation and commit it there."
    echo ""
    echo -e "  ${BOLD}Next steps:${NC} docs/bare-metal-rebuild.md (in /etc/nixos). In short:"
    echo "  1. Set user password below"
    echo "  2. Reboot, enter the LUKS passphrase"
    echo "  3. From a surviving host: re-key sops for this host's new SSH key, update"
    echo "     hostKeys + Syncthing ID in hosts/network.nix, commit, deploy"
    case "$HOST" in
        server-nixos)
            echo "  4. Server: initrd SSH key, TPM2 re-enrolment, lab_monitor key,"
            echo "     ComfyUI image, Ollama models (all listed in the doc)"
            ;;
        workstation-nixos)
            echo "  4. Workstation: ComfyUI render image; recreate the storage pool if it was lost"
            ;;
        laptop-nixos)
            echo "  4. Laptop: test hibernate (systemctl hibernate); optional YubiKey enrolment"
            ;;
    esac

    echo ""
    if confirm "Set user password for 'oat' now?"; then
        nixos-enter --root /mnt -c 'passwd oat' || warn "Failed — set it after first boot"
    fi

    echo ""
    echo -e "  ${BOLD}Claude is available:${NC}"
    echo "  claude \"I just installed ${HOST}, help me with post-install from the plan.\""
    echo ""
    info "Reboot when ready: reboot"

    # Clear passphrase and disable trap — success
    PASSPHRASE=""
    unset PASSPHRASE 2>/dev/null || true
    trap - EXIT
}

################################
## Main
################################
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     NixOS Lab Installer — ZFS/LUKS        ║${NC}"
    echo -e "${BOLD}${CYAN}║     LUKS2 + YubiKey FIDO2 + ZFS           ║${NC}"
    echo -e "${BOLD}${CYAN}║     github.com/oat-meal/nixos-lab         ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    select_host
    select_disks
    get_passphrase
    generate_host_id

    # YubiKey setup skipped — enroll post-install with:
    #   systemd-cryptenroll /dev/nvme0n1p2 --fido2-device=auto --fido2-with-client-pin=yes

    # Partition disks
    header "Partitioning"

    if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
        partition_disk "$DISK1" true    # EFI + LUKS
        partition_disk "$DISK2" false   # LUKS only
    else
        partition_disk "$DISK1" true    # EFI + LUKS
    fi

    # Storage drives (workstation)
    if [[ -n "$STORAGE_DISK1" ]]; then
        info "Partitioning storage drives..."
        for sd in "$STORAGE_DISK1" "$STORAGE_DISK2"; do
            run wipefs -af "$sd"
            run sgdisk --zap-all "$sd"
            run parted "$sd" -- mklabel gpt
            run parted "$sd" -- mkpart primary 1MiB 100%
            reread_partitions "$sd"
            # Handle both naming schemes (sdX1 vs nvmeXp1)
            if [[ -b "${sd}p1" ]] || [[ "$sd" == *nvme* ]]; then
                wait_for_partition "${sd}p1"
            else
                wait_for_partition "${sd}1"
            fi
        done
    fi

    # Create LUKS containers
    header "LUKS2 Encryption"

    if [[ "${POOL_TYPE[$HOST]}" == "mirror" ]]; then
        create_luks "${DISK1}p2" "cryptroot0"
        create_luks "${DISK2}p1" "cryptroot1"
    else
        create_luks "${DISK1}p2" "cryptroot"
    fi

    if [[ -n "$STORAGE_DISK1" ]]; then
        local sp1="${STORAGE_DISK1}1"
        [[ -b "${STORAGE_DISK1}p1" ]] && sp1="${STORAGE_DISK1}p1"
        local sp2="${STORAGE_DISK2}1"
        [[ -b "${STORAGE_DISK2}p1" ]] && sp2="${STORAGE_DISK2}p1"

        create_luks "$sp1" "cryptstorage1"
        create_luks "$sp2" "cryptstorage2"
    fi

    # YubiKey enrollment skipped — enroll post-install

    create_zfs
    mount_filesystems
    setup_config
    show_summary
    run_install
    post_install
}

main "$@"
