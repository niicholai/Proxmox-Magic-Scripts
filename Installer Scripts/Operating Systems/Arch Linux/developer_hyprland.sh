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

# v35 Fix: Use variables for paths
IMAGE_DIR="/var/lib/vz/images"
SNIPPETS_DIR="/var/lib/vz/snippets"

# User settings
NEW_USERNAME="dev"

# SSH key (v28 check)
SSH_KEYS_FILE="${HOME}/.ssh/authorized_keys"
if [ ! -r "$SSH_KEYS_FILE" ] || ! grep -q -E "^ssh" "$SSH_KEYS_FILE"; then
    echo "ERROR: Failed to read a valid public SSH key from ${SSH_KEYS_FILE}."
    echo "Please add your valid *.pub key to that file."
    exit 1
fi

# Image settings
IMAGE_URL="https://fastly.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_FILE="$IMAGE_DIR/Arch-Linux-x86_64-cloudimg.qcow2"

# --- Helper Functions ---
function log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

# --- 1. Download Arch Cloud-Image (if it doesn't exist) ---
mkdir -p $IMAGE_DIR
if [ ! -f "$IMAGE_FILE" ]; then
    log "Downloading Arch Linux cloud image to $IMAGE_FILE..."
    wget -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# --- 2. Create Cloud-Init Config Snippet ---
log "Creating Cloud-Init config snippet..."
mkdir -p $SNIPPETS_DIR
SNIPPET_PATH="${SNIPPETS_DIR}/cloud-init-${VM_NAME}.yaml"

cat > $SNIPPET_PATH << EOF
#cloud-config
fqdn: ${VM_NAME}
ssh_pwauth: false

# We only modify the 'root' user (reliable method)
users:
  - name: root
    groups: docker
    # v35 Fix: Use robust awk command, not grep|xargs
    ssh_authorized_keys:
$(awk '/^ssh/ {printf "      - %s\n", $0}' "${SSH_KEYS_FILE}")

# v35 Fix: Use BARE STRINGS for runcmd (reliable method)
runcmd:
  # --- 1. v35 FIX: Resize the filesystem *before* installing packages ---
  - pacman -Syu --noconfirm --needed cloud-utils-growpart e2fsprogs
  - growpart /dev/sda 1
  - resize2fs /dev/sda1
  
  # --- 2. THE GPG FIX ---
  - sh -c "rm -rf /etc/pacman.d/gnupg"
  - pacman-key --init
  - pacman-key --populate archlinux
  
  # --- 3. System Update & Base Tools ---
  - pacman -Syu --noconfirm
  - pacman -S --noconfirm qemu-guest-agent sudo
  - systemctl enable --now qemu-guest-agent
  
  # --- 4. Create our 'dev' user manually (reliable method) ---
  - useradd -m -G wheel,docker -s /bin/bash ${NEW_USERNAME}
  - sh -c "echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd"
  
  # --- 5. Copy SSH keys from root to new user ---
  - mkdir -p /home/${NEW_USERNAME}/.ssh
  - sh -c "cp /root/.ssh/authorized_keys /home/${NEW_USERNAME}/.ssh/authorized_keys"
  - chown -R ${NEW_USERNAME}:${NEW_USERNAME} /home/${NEW_USERNAME}/.ssh
  - chmod 700 /home/${NEW_USERNAME}/.ssh
  - chmod 600 /home/${NEW_USERNAME}/.ssh/authorized_keys

  # --- 6. Install Our GUI/Dev Apps ---
  - pacman -S --noconfirm base-devel git hyprland alacritty kitty neovim nodejs npm python python-pip go docker docker-compose firefox chromium thunderbird samba
  
  # --- 7. Enable Services (The v26 fix) ---
  - systemctl enable docker
  - systemctl enable smb
  - systemctl enable nmb
  
  # --- 8. Autologin & Hyprland Start (for the NEW user) ---
  - mkdir -p /etc/systemd/system/getty@tty1.service.d
  - sh -c "echo '[Service]' > /etc/systemd/system/getty@tty1.service.d/override.conf"
  - sh -c "echo 'ExecStart=' >> /etc/systemd/system/getty@tty1.service.d/override.conf"
  - sh -c "echo 'ExecStart=-/sbin/agetty --autologin ${NEW_USERNAME} --noclear %I \$TERM' >> /etc/systemd/system/getty@tty1.service.d/override.conf"
  - systemctl daemon-reload
  # v35 Fix: Correctly escape $() for bare string EOF
  - sh -c "echo 'if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then exec Hyprland; fi' >> /home/${NEW_USERNAME}/.bash_profile"
  - chown ${NEW_USERNAME}:${NEW_USERNAME} /home/${NEW_USERNAME}/.bash_profile
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
log "VM ${VMID} is booting. This is v35."
log "Watch with: qm terminal $VMID"