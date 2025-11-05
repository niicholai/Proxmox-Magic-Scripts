#!/usr/bin/env bash

# --- Configuration Variables ---
VMID=201
VM_NAME="arch-dev-vm"
CPU_CORES=8
RAM_MB=12288
DISK_SIZE=150G
DISK_CACHE="writethrough"
BRIDGE="vmbr0"
STORAGE="local-zfs"     # Storage for the new VM disk
LOCAL_STORAGE="local"   # Storage for the Cloud-Init snippet & qcow2 image

# User settings
USERNAME="dev"
PASSWORD="password"

# Image settings
IMAGE_URL="https://fastly.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_DIR="/var/lib/vz/images" # Correct path for 'local' storage images
IMAGE_FILE="$IMAGE_DIR/Arch-Linux-x86_64-cloudimg.qcow2"

# --- Helper Functions ---
function log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

# --- 1. Get SSH Key Interactively (MANDATORY) ---
echo "--- SSH Key Setup ---"
echo "This script REQUIRES a public SSH key to create the user."
read -p "Your SSH Public Key: " PUB_KEY

if [ -z "$PUB_KEY" ]; then
    log "ERROR: No SSH key provided. This script cannot continue."
    exit 1
fi

# --- 2. Download Arch Cloud-Image (if it doesn't exist) ---
if [ ! -f "$IMAGE_FILE" ]; then
    log "Downloading Arch Linux cloud image to $IMAGE_FILE..."
    mkdir -p $IMAGE_DIR
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# --- 3. Create Cloud-Init Config Snippet ---
log "Creating Cloud-Init config snippet..."
SNIPPET_PATH="/var/lib/vz/snippets/cloud-init-${VM_NAME}.yaml"

# Create the base YAML file
cat > $SNIPPET_PATH << EOF
#cloud-config

# Using the 'users' and 'chpasswd' structure
users:
  - name: ${USERNAME}
    gecos: ${USERNAME}
    groups: [wheel, docker]
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUB_KEY}

chpasswd:
  expire: false
  list:
    - ${USERNAME}:${PASSWORD}

ssh_pwauth: true

runcmd:
  # --- 1. THE GPG FIX ---
  - [ sh, -c, "rm -rf /etc/pacman.d/gnupg" ]
  - [ pacman-key, --init ]
  - [ pacman-key, --populate, archlinux ]
  
  # --- 2. System Update & Base Tools ---
  - [ pacman, -Syu, --noconfirm ]
  - [ pacman, -S, --noconfirm, qemu-guest-agent ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
  
  # --- 3. Install GUI/Dev Apps ---
  - [ pacman, -S, --noconfirm, base-devel, git, sudo, hyprland, alacritty, kitty, neovim, nodejs, npm, python, python-pip, go, docker, docker-compose, firefox, chromium, thunderbird, notepadqq, samba ]
  
  # --- 4. Enable Services ---
  - [ systemctl, enable, --now, docker ]
  - [ systemctl, enable, --now, smb ]
  - [ systemctl, enable, --now, nmb ]
  - [ systemd-tmpfiles, --create, docker.conf ]
  
  # --- 5. Autologin & Hyprland Start ---
  - mkdir -p /etc/systemd/system/getty@tty1.service.d
  - |
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOL
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
    EOL
  - systemctl daemon-reload
  - |
    echo '
    if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
      exec Hyprland
    fi' >> /home/${USERNAME}/.bash_profile
  - chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile
EOF

# --- 4. Create and Configure VM ---
log "Destroying old VM ${VMID} (if exists)..."
qm destroy $VMID --purge || true

log "Creating VM ${VMID} (${VM_NAME})..."
qm create $VMID --name $VM_NAME --memory $RAM_MB --cores $CPU_CORES \
    --net0 virtio,bridge=$BRIDGE --ostype l26 --onboot 1 \
    --scsihw virtio-scsi-pci

log "Setting CPU type to 'host'..."
qm set $VMID --cpu host

log "Setting machine type to 'q35'..."
qm set $VMID --machine q35

# --- GUI ---
log "Setting display to QXL for SPICE..."
qm set $VMID --vga qxl

# --- Enable guest agent ---
log "Enabling QEMU Guest Agent..."
qm set $VMID --agent 1

log "Importing disk from $IMAGE_FILE to $STORAGE..."
qm disk import $VMID "$IMAGE_FILE" $STORAGE

log "Cleaning up downloaded qcow2 file..."
rm "$IMAGE_FILE"
log "Removed $IMAGE_FILE."

log "Attaching imported disk with performance options..."
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0,cache=$DISK_CACHE,discard=on,ssd=1,queues=$CPU_CORES
qm set $VMID --boot order=scsi0

log "Attaching Cloud-Init drive..."
qm set $VMID --ide2 $STORAGE:cloudinit

# --- Proxmox handles network ---
log "Setting Cloud-Init networking (via Proxmox)..."
qm set $VMID --ipconfig0 ip=dhcp

log "Setting serial console (for debugging)..."
qm set $VMID --serial0 socket

# ---Use cicustom AND ciuser ---
qm set $VMID --cicustom "user=local:snippets/cloud-init-${VM_NAME}.yaml"
qm set $VMID --ciuser $USERNAME

log "Resizing disk..."
qm resize $VMID scsi0 ${DISK_SIZE}

log "Starting VM ${VMID}..."
qm start $VMID

log "--- All Done! ---"
log "VM ${VMID} is booting."
log "It includes the GPG-key fix, so it will take a LONG time (10-15 min) to run pacman."
log "Watch with: qm terminal $VMID"
log "You should see NO schema warnings."
log "After 15-20 min, open the SPICE console. You should see Hyprland."