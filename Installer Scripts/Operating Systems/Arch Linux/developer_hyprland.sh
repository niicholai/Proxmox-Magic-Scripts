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

# --- 1. Get SSH Key Interactively ---
echo "--- SSH Key Setup ---"
echo "Please paste your SSH public key (e.g., 'ssh-rsa AAAA...')."
echo "This will be added to the 'dev' user."
echo "Press ENTER to skip and use password-only."
read -p "Your SSH Key: " PUB_KEY

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

# --- User Configuration ---
user:
  name: ${USERNAME}
  passwd: "${PASSWORD}"
  chpasswd: { expire: False }
  sudo: ['ALL=(ALL) NOPASSWD:ALL']
  groups: [wheel, docker]
  shell: /bin/bash
ssh_pwauth: true

runcmd:
  # 1. Init pacman keys (still a good idea)
  - [ pacman-key, --init ]
  - [ pacman-key, --populate ]

  # 2. Set up autologin to Hyprland
  - mkdir -p /etc/systemd/system/getty@tty1.service.d
  - |
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOL
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
    EOL
  - systemctl daemon-reload
  
  # 3. Set up .bash_profile to auto-start Hyprland
  - |
    echo '
    if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
      exec Hyprland
    fi' >> /home/${USERNAME}/.bash_profile
  - chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile
EOF

# --- Conditionally add the SSH key ---
if [ -n "$PUB_KEY" ]; then
    log "Adding provided public SSH key..."
    sed -i "/^  shell: \/bin\/bash/a\  ssh_authorized_keys:\n    - ${PUB_KEY}" $SNIPPET_PATH
else
    log "No SSH key provided. Skipping."
fi

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

log "Setting Cloud-Init networking (via Proxmox)..."
qm set $VMID --ipconfig0 ip=dhcp

log "Setting serial console..."
qm set $VMID --serial0 socket
qm set $VMID --cicustom "user=local:snippets/cloud-init-${VM_NAME}.yaml"

log "Setting CI user..."
qm set $VMID --ciuser $USERNAME

log "Resizing disk..."
qm resize $VMID scsi0 ${DISK_SIZE}

log "Starting VM ${VMID}..."
qm start $VMID

log "--- All Done! ---"
log "VM ${VMID} is provisioned and booting. This will be fast."
log "Network and SSH are configured. Package installation is NOT."
log ""
log "--- YOUR NEXT STEP ---"
log "1. Wait 60 seconds for the VM to boot."
log "2. Find the VM's IP in the Proxmox summary (or your DHCP server)."
log "3. SSH in: ssh ${USERNAME}@[VM_IP_ADDRESS]"
log "4. Once inside, run the package installation command manually:"
log ""
log "sudo pacman -Syu --noconfirm && sudo pacman -S --noconfirm base-devel git sudo hyprland alacritty kitty neovim nodejs npm python python-pip go docker docker-compose firefox chromium thunderbird notepadqq samba && sudo systemctl enable --now docker smb nmb"
log ""