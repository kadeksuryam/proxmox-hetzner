#!/usr/bin/env bash
set -Eeuo pipefail

###########################################################
#  Proxmox Auto-Installer Script
###########################################################

#-----------------------------
#  Colors for output
#-----------------------------
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_RESET="\033[m"

#-----------------------------
#  Error trap
#-----------------------------
trap 'echo -e "${CLR_RED}[ERROR] Script failed at line $LINENO. Exiting.${CLR_RESET}" >&2; exit 1' ERR

#-----------------------------
#  Helper log functions
#-----------------------------
log()    { echo -e "${CLR_GREEN}[INFO]${CLR_RESET} $*"; }
warn()   { echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $*"; }
error()  { echo -e "${CLR_RED}[ERROR]${CLR_RESET} $*"; }
section(){ echo -e "\n${CLR_BLUE}=== $* ===${CLR_RESET}\n"; }

#-----------------------------
#  Ensure script runs as root
#-----------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi
}

#-----------------------------
#  Required commands
#-----------------------------
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} )); then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

#===========================================================
#   CONFIG LOADING
#===========================================================
CONFIG_FILE="${CONFIG_FILE:-./.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    source "$CONFIG_FILE"
    set +a
else
    echo "[ERROR] Config file $CONFIG_FILE not found." >&2
    exit 1
fi

#===========================================================
#   FUNCTIONS
#===========================================================

init_validation() {
    require_root
    require_cmds ip curl awk sed qemu-system-x86_64 sshpass nc wget

    : "${HOSTNAME:?HOSTNAME not set in $CONFIG_FILE}"
    : "${FQDN:?FQDN not set in $CONFIG_FILE}"
    : "${TIMEZONE:?TIMEZONE not set in $CONFIG_FILE}"
    : "${EMAIL:?EMAIL not set in $CONFIG_FILE}"
    : "${ROOT_PASSWORD:?ROOT_PASSWORD not set in $CONFIG_FILE}"
    : "${HOST_INTERFACE:?HOST_INTERFACE not set in $CONFIG_FILE}"
    : "${HOST_IPV4_GW:?HOST_IPV4_GW not set in $CONFIG_FILE}"
    : "${HOST_IPV4_ADDR:?HOST_IPV4_ADDR not set in $CONFIG_FILE}"
    : "${HOST_IPV6_ADDR:?HOST_IPV6_ADDR not set in $CONFIG_FILE}"
    : "${HOST_IPV6_GW:?HOST_IPV6_GW not set in $CONFIG_FILE}"
}

init() {
    section "Init"
    init_validation

    log "Setting up apt sources for Proxmox..."
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list
    curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg

    apt update && apt install -yq --no-install-recommends proxmox-auto-install-assistant xorriso ovmf wget sshpass

    log "Preparing template files..."
    mkdir -p ./files
    curl -fsSLo ./files/99-proxmox.conf https://github.com/kadeksuryam/proxmox-hetzner/raw/refs/heads/main/templates/99-proxmox.conf
    curl -fsSLo ./files/answer.toml https://github.com/kadeksuryam/proxmox-hetzner/raw/refs/heads/main/templates/answer.toml
    curl -fsSLo ./files/hosts https://github.com/kadeksuryam/proxmox-hetzner/raw/refs/heads/main/templates/hosts
    curl -fsSLo ./files/interfaces https://github.com/kadeksuryam/proxmox-hetzner/raw/refs/heads/main/templates/interfaces

    # Update answer.toml
    sed -i "s|{{FQDN}}|$FQDN|g" ./files/answer.toml
    sed -i "s|{{EMAIL}}|$EMAIL|g" ./files/answer.toml
    sed -i "s|{{TIMEZONE}}|$TIMEZONE|g" ./files/answer.toml
    sed -i "s|{{ROOT_PASSWORD}}|$ROOT_PASSWORD|g" ./files/answer.toml

    # Update hosts
    sed -i "s|{{HOST_IPV4_ADDR}}|$HOST_IPV4_ADDR|g" ./files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./files/hosts
    sed -i "s|{{HOSTNAME}}|$HOSTNAME|g" ./files/hosts
    sed -i "s|{{HOST_IPV6_ADDR}}|$HOST_IPV6_ADDR|g" ./files/hosts

    # Update interfaces
    sed -i "s|{{HOST_INTERFACE}}|$HOST_INTERFACE|g" ./files/interfaces
    sed -i "s|{{HOST_IPV4_ADDR}}|$HOST_IPV4_ADDR|g" ./files/interfaces
    sed -i "s|{{HOST_IPV4_GW}}|$HOST_IPV4_GW|g" ./files/interfaces
    sed -i "s|{{HOST_IPV6_ADDR}}|$HOST_IPV6_ADDR|g" ./files/interfaces
    sed -i "s|{{HOST_IPV6_GW}}|$HOST_IPV6_GW|g" ./files/interfaces

    log "Templates initialized successfully."
}

build_proxmox_iso() {
    section "Get-Update Proxmox ISO"
    local base_url="https://enterprise.proxmox.com/iso/"
    local latest_iso

    latest_iso=$(curl -s "$base_url" | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n1)
    [[ -z "$latest_iso" ]] && error "No Proxmox VE ISO found." && exit 1

    wget -qO pve.iso "${base_url}${latest_iso}"
    log "Downloaded latest Proxmox ISO: $latest_iso"

    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file files/answer.toml --output pve-autoinstall.iso
    log "pve-autoinstall.iso created."
}

is_uefi_mode() { [ -d /sys/firmware/efi ]; }

install_proxmox() {
    section "Installing Proxmox VE"
    local UEFI_OPTS=""
    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        log "UEFI Supported! Booting with UEFI firmware."
    else
        log "UEFI Not Supported! Booting in legacy mode."
    fi

    echo -e "${CLR_RED}Do NOT touch anything, just wait 5–10 min!${CLR_RESET}"

    # Build drives dynamically
    local DRIVES=""
    [[ -e /dev/nvme0n1 ]] && DRIVES="$DRIVES -drive file=/dev/nvme0n1,format=raw,media=disk,if=virtio"
    [[ -e /dev/nvme1n1 ]] && DRIVES="$DRIVES -drive file=/dev/nvme1n1,format=raw,media=disk,if=virtio"

    qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -smp 4 -m 4096 \
        -boot d -cdrom ./pve-autoinstall.iso \
        $DRIVES \
        -no-reboot -display none > qemu_install.log 2>&1
}

boot_proxmox() {
    section "Booting installed Proxmox with SSH port forwarding"
    local UEFI_OPTS=""
    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
    fi

    # Build drives dynamically
    local DRIVES=""
    [[ -e /dev/nvme0n1 ]] && DRIVES="$DRIVES -drive file=/dev/nvme0n1,format=raw,media=disk,if=virtio"
    [[ -e /dev/nvme1n1 ]] && DRIVES="$DRIVES -drive file=/dev/nvme1n1,format=raw,media=disk,if=virtio"

    nohup qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -smp 4 -m 4096 \
        $DRIVES \
        > qemu_output.log 2>&1 &

    QEMU_PID=$!
    log "QEMU started with PID: $QEMU_PID"

    log "Waiting for SSH to become available on port 2222..."
    for i in {1..60}; do
        if nc -z localhost 2222; then
            log "SSH is available on port 2222."
            return 0
        fi
        echo -n "."
        sleep 5
    done

    error "SSH not available after 5 minutes. Check logs (qemu_output.log)."
    return 1
}

configure_proxmox() {
    section "Configuring Proxmox"

    ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:2222" || true

    # Explicit destinations
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/hosts root@localhost:/etc/hosts
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/interfaces root@localhost:/etc/network/interfaces
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf

    log "Patching Proxmox settings..."
    sshpass -p "$ROOT_PASSWORD" ssh -p 2222 -o StrictHostKeyChecking=no root@localhost "
        sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/pve-enterprise.list || true
        sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/ceph.list || true

        echo $HOSTNAME > /etc/hostname
        systemctl disable --now rpcbind rpcbind.socket

        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js{,.bak}
            sed -Ezi \"s/(Ext.Msg.show\\(\\{\\s+title: gettext\\('No valid sub)/void(\\{ \\/\\/\\1/g\" \
                /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
            echo 'Subscription popup removed.'
        fi

        if [ \"${RESTRICT_GUI_TO_LOCALHOST:-true}\" = \"true\" ]; then
            grep -q '^LISTEN_IP=' /etc/default/pveproxy || echo 'LISTEN_IP=\"127.0.0.1\"' >> /etc/default/pveproxy
            systemctl restart pveproxy
            echo 'Proxmox GUI restricted to localhost only.'
        fi
    "
}

post_install_optimizations() {
    section "Post-Installation Optimizations"

    ARC_MIN=$((8 * 1024 * 1024 * 1024))
    ARC_MAX=$((16 * 1024 * 1024 * 1024))

    sshpass -p "$ROOT_PASSWORD" ssh -p 2222 -o StrictHostKeyChecking=no root@localhost "
        echo 'Updating packages...'
        apt update && apt -y upgrade && apt -y autoremove && pveupgrade && pveam update

        echo 'Installing useful utilities...'
        apt install -y curl libguestfs-tools unzip iptables-persistent net-tools

        echo 'Applying nf_conntrack sysctl tweaks...'
        echo 'nf_conntrack' >> /etc/modules
        echo 'net.netfilter.nf_conntrack_max=1048576' >> /etc/sysctl.d/99-proxmox.conf
        echo 'net.netfilter.nf_conntrack_tcp_timeout_established=28800' >> /etc/sysctl.d/99-proxmox.conf

        echo 'Tuning ZFS ARC...'
        echo "options zfs zfs_arc_min=${ARC_MIN}" >> /etc/modprobe.d/99-zfs.conf
        echo "options zfs zfs_arc_max=${ARC_MAX}" >> /etc/modprobe.d/99-zfs.conf
        update-initramfs -u
    "
}

reboot_to_main_os() {
    section "Final Steps"
    echo -e "${CLR_YELLOW}Proxmox installation completed.${CLR_RESET}"
    echo -e "${CLR_GREEN}After shutting down the VM, you can access Proxmox via SSH tunnel:\n  ssh -L 8006:127.0.0.1:8006 root@server${CLR_RESET}"

    log "Powering off the QEMU VM..."
    sshpass -p "$ROOT_PASSWORD" ssh -p 2222 -o StrictHostKeyChecking=no root@localhost "poweroff" || true
    wait $QEMU_PID || true
    log "VM stopped. Physical host NOT rebooted."
}

#===========================================================
#   MAIN EXECUTION FLOW
#===========================================================
section "Starting Proxmox Auto-Installation"
init
build_proxmox_iso
install_proxmox

log "Waiting for installation to complete..."
boot_proxmox || { error "Failed to boot Proxmox with port forwarding. Exiting."; exit 1; }

configure_proxmox
post_install_optimizations
reboot_to_main_os
