#!/usr/bin/env bash

# --- Configuration Variables ---
VMID=202
VM_NAME="fedora-dev-vm"
CPU_CORES=8
RAM_MB=12288
DISK_SIZE=150G
DISK_CACHE="writethrough"
BRIDGE="vmbr0"
STORAGE="local-zfs"

# Use variables for paths
IMAGE_DIR="/var/lib/vz/images"
SNIPPETS_DIR="/var/lib/vz/snippets"

# User settings
USERNAME="dev"

# SSH key
SSH_KEYS_FILE="${HOME}/.ssh/authorized_keys"
if [ ! -r "$SSH_KEYS_FILE" ] || ! grep -q -E "^ssh" "$SSH_KEYS_FILE"; then
    echo "ERROR: Failed to read a valid public SSH key from ${SSH_KEYS_FILE}."
    echo "Please add your valid *.pub key to that file."
    exit 1
fi

# Image settings
IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
IMAGE_FILE="$IMAGE_DIR/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"

# --- Helper Functions ---
function log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

# --- 1. Download Fedora Cloud-Image (if it doesn't exist) ---
mkdir -p $IMAGE_DIR
if [ ! -f "$IMAGE_FILE" ]; then
    log "Downloading Fedora 41 cloud image..."
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# --- 2. Create Cloud-Init Config Snippet ---
log "Creating Cloud-Init config snippet..."
mkdir -p $SNIPPETS_DIR
SNIPPET_PATH="${SNIPPETS_DIR}/cloud-init-${VM_NAME}.yaml"

# --- v1-Fedora: A clean, standard Cloud-Init file ---
cat > $SNIPPET_PATH << EOF
#cloud-config
fqdn: ${VM_NAME}
ssh_pwauth: false

# We can create the user directly. This is not Arch.
users:
  - name: ${USERNAME}
    gecos: ${USERNAME}
    groups: [wheel, docker] # 'wheel' is the sudo group on Fedora
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
$(awk '/^ssh/ {printf "      - %s\n", $0}' "${SSH_KEYS_FILE}")

# Use the standard 'list of lists' format, which Fedora supports.
runcmd:
  # --- 1. Resize the filesystem (Fedora uses XFS) ---
  # The root partition is partition 4 on the Fedora cloud image
  - [ dnf, install, -y, cloud-utils-growpart, xfsprogs ]
  - [ growpart, /dev/sda, 4 ]
  - [ xfs_growfs, / ]
  
  # --- 2. System Update & Base Tools ---
  - [ dnf, update, -y ]
  - [ dnf, install, -y, qemu-guest-agent ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
  
  # --- 3. Install Dev Tools & Apps ---
  - [ dnf, groupinstall, -y, "Development Tools" ]
  - [ dnf, install, -y, hyprland, alacritty, kitty, neovim, nodejs, npm, python3, python3-pip, golang, docker, docker-compose, firefox, chromium, thunderbird, samba ]
  
  # --- 4. Enable Services ---
  - [ systemctl, enable, docker ]
  - [ systemctl, enable, smb ]
  - [ systemctl, enable, nmb ]
  
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

log "Setting Cloud-Init (The *Working* Way)..."
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --sshkey "${SSH_KEYS_FILE}"
# v35 Fix: Use variable for snippet path
qm set $VMID --cicustom "user=local:snippets/cloud-init-${VM_NAME}.yaml"
qm set $VMID --serial0 socket

log "Resizing disk..."
qm resize $VMID scsi0 ${DISK_SIZE}

log "Starting VM ${VMID}..."
qm start $VMID

log "--- All Done! ---"
log "VM ${VMID} is booting. This is v1-Fedora."
log "Fedora's 'dnf update' can be slow. Give this 15-20 minutes."
log "Watch with: qm terminal $VMID"