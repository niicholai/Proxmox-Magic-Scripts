#!/usr/bin/env bash

# --- Configuration Variables ---
VMID=201
VM_NAME="arch-dev-vm"
CPU_CORES=8
RAM_MB=12288
DISK_SIZE=150G
DISK_CACHE="writethrough"
BRIDGE="vmbr0"
STORAGE="local-zfs"
LOCAL_STORAGE="local"

# User settings
USERNAME="dev"
# PASSWORD="password" # We will not set a password, SSH key is mandatory

# SSH key is now MANDATORY for user creation
SSH_KEYS_FILE="${HOME}/.ssh/authorized_keys"
if [ ! -f "$SSH_KEYS_FILE" ]; then
    echo "ERROR: This script requires an SSH key at ${SSH_KEYS_FILE} to create the user."
    echo "Please paste your public key into that file or update the SSH_KEYS_FILE variable."
    exit 1
fi

# Image settings
IMAGE_URL="https://fastly.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_DIR="/var/lib/vz/images"
IMAGE_FILE="$IMAGE_DIR/Arch-Linux-x86_64-cloudimg.qcow2"

# --- Helper Functions ---
function log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

# --- 1. Download Arch Cloud-Image (if it doesn't exist) ---
if [ ! -f "$IMAGE_FILE" ]; then
    log "Downloading Arch Linux cloud image to $IMAGE_FILE..."
    mkdir -p $IMAGE_DIR
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# --- 2. Create Cloud-Init Config Snippet ---
log "Creating Cloud-Init config snippet..."
SNIPPET_PATH="/var/lib/vz/snippets/cloud-init-${VM_NAME}.yaml"

# --- v25: Build the YAML file (Hardcoded for 100% accuracy) ---
cat > $SNIPPET_PATH << EOF
#cloud-config
fqdn: ${VM_NAME}
ssh_pwauth: false
users:
  - name: ${USERNAME}
    gecos: ${USERNAME}
    groups: [wheel, docker]
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
$(cat ${SSH_KEYS_FILE} | grep -E "^ssh" | xargs -iXX echo "      - XX")

# v25: Removed deprecated 'chpasswd' block. SSH key is now the only login.

runcmd:
  # --- 1. THE GPG FIX ---
  - [ sh, -c, "rm -rf /etc/pacman.d/gnupg" ]
  - [ pacman-key, --init ]
  - [ pacman-key, --populate, archlinux ]
  
  # --- 2. System Update & Base Tools ---
  - [ pacman, -Syu, --noconfirm ]
  - [ pacman, -S, --noconfirm, qemu-guest-agent ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
  
  # --- 3. Install ALL Our GUI/Dev Apps ---
  # v25 BUGFIX: Added '--noconfirm' and removed 'notepadqq' (it's in AUR)
  - [ pacman, -S, --noconfirm, base-devel, git, sudo, hyprland, alacritty, kitty, neovim, nodejs, npm, python, python-pip, go, docker, docker-compose, firefox, chromium, thunderbird, samba ]
  
  # --- 4. Enable Services ---
  - [ systemctl, enable, --now, docker ]
  - [ systemctl, enable, --now, smb ]
  - [ systemctl, enable, --now, nmb ]
  - [ systemd-tmpfiles, --create, docker.conf ]
  
  # --- 5. Autologin & Hyprland Start ---
  - [ mkdir, -p, /etc/systemd/system/getty@tty1.service.d ]
  - [ sh, -c, "echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/override.conf" ]
  - [ sh, -c, "echo 'ExecStart=' >> /etc/systemd/system/getty@tty1.service.d/override.conf" ]
  - [ sh, -c, "echo 'ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM' >> /etc/systemd/system/getty@tty1.service.d/override.conf" ]
  - [ systemctl, daemon-reload ]
  - [ sh, -c, "echo 'if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then exec Hyprland; fi' >> /home/${USERNAME}/.bash_profile" ]
  - [ chown, "${USERNAME}:${USERNAME}", /home/${USERNAME}/.bash_profile ]
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

log "Setting display to QXL for SPICE..."
qm set $VMID --vga qxl

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

# --- v24's Winning Combo ---
log "Setting Cloud-Init (The *Working* Way)..."
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --sshkey "${SSH_KEYS_FILE}"
qm set $VMID --cicustom "user=local:snippets/cloud-init-${VM_NAME}.yaml"
qm set $VMID --serial0 socket
# --- END COMBO ---

log "Resizing disk..."
qm resize $VMID scsi0 ${DISK_SIZE}

log "Starting VM ${VMID}..."
qm start $VMID

log "--- All Done! ---"
log "VM ${VMID} is booting. This is v25 (the v24 bugfix)."
log "This WILL take 10-15 minutes. The serial console will hang while 'pacman' runs."
log "Watch with: qm terminal $VMID"
log "After 15-20 min, open the SPICE console. You should see Hyprland."