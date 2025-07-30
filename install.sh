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
#  Auto-install required commands
#-----------------------------
ensure_cmds() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} )); then
        log "Installing missing commands: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -yq "${missing[@]}"
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
    ensure_cmds ip curl awk sed qemu-system-x86_64 sshpass nc wget

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

    apt-get update && apt-get install -yq --no-install-recommends proxmox-auto-install-assistant xorriso ovmf sshpass

    log "Preparing template files..."
    mkdir -p ./files
    cp ./templates/99-proxmox.conf ./files/99-proxmox.conf 
    cp ./templates/answer.toml ./files/answer.toml 
    cp ./templates/hosts ./files/hosts 
    cp ./templates/interfaces ./files/interfaces
    cp ./templates/iptables-rules.v4 ./files/iptables-rules.v4

    # Update answer.toml
    sed -i "s|{{FQDN}}|\"$FQDN\"|g" ./files/answer.toml
    sed -i "s|{{EMAIL}}|\"$EMAIL\"|g" ./files/answer.toml
    sed -i "s|{{TIMEZONE}}|\"$TIMEZONE\"|g" ./files/answer.toml
    sed -i "s|{{ROOT_PASSWORD}}|\"$ROOT_PASSWORD\"|g" ./files/answer.toml

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

    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/hosts root@localhost:/etc/hosts
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/interfaces root@localhost:/etc/network/interfaces
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf
    sshpass -p "$ROOT_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no files/iptables-rules.v4 root@localhost:/root/rules.v4

    ARC_MIN=$((8 * 1024 * 1024 * 1024))
    ARC_MAX=$((16 * 1024 * 1024 * 1024))

    sshpass -p "$ROOT_PASSWORD" ssh -p 2222 -o StrictHostKeyChecking=no root@localhost "
        echo 'Updating packages...'
        apt-get update && apt-get -y upgrade && apt-get -y autoremove && pveupgrade && pveam update

        echo 'Installing utilities...'
        echo 'iptables-persistent iptables-persistent/autosave_v4 boolean true' | debconf-set-selections
        echo 'iptables-persistent iptables-persistent/autosave_v6 boolean true' | debconf-set-selections

        DEBIAN_FRONTEND=noninteractive apt-get install -y curl libguestfs-tools unzip iptables-persistent net-tools

        echo 'Updating iptables...'
        mkdir -p /etc/iptables
        mv /root/rules.v4 /etc/iptables/rules.v4
        systemctl enable --now netfilter-persistent
        netfilter-persistent reload

        echo 'Configuring ZFS...'
        echo "options zfs zfs_arc_min=${ARC_MIN}" >> /etc/modprobe.d/99-zfs.conf
        echo "options zfs zfs_arc_max=${ARC_MAX}" >> /etc/modprobe.d/99-zfs.conf
        update-initramfs -u
    "

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
reboot_to_main_os
