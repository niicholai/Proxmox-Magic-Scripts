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

# --- v17 Change: Network Configuration ---
# This uses version 2 and EXPLICITLY sets the renderer to 'networkd',
# which is what the Arch Linux image uses. This should prevent
# the 125-second timeout and schema validation errors.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true

# --- Package Management ---
package_update: true
package_upgrade: true
packages:
  - base-devel
  - git
  - sudo
  - hyprland
  - alacritty
  - kitty
  - neovim
  - nodejs
  - npm
  - python
  - python-pip
  - go
  - docker
  - docker-compose
  - firefox
  - chromium
  - thunderbird
  - onlyoffice-bin
  - notepadqq
  - samba

# --- Post-Install Commands ---
runcmd:
  # 1. Init pacman keys (just in case)
  - [ pacman-key, --init ]
  - [ pacman-key, --populate ]
  
  # 2. Enable and start services
  - [ systemctl, enable, docker ]
  - [ systemd-tmpfiles, --create, docker.conf ] # Fix for Docker on Arch
  - [ systemctl, start, docker ]
  - [ systemctl, enable, smb ]
  - [ systemctl, enable, nmb ]
  - [ systemctl, start, smb ]
  - [ systemctl, start, nmb ]
  
  # 3. Clone crush and install
  - git clone https://github.com/charmbracelet/crush.git /opt/crush
  - cd /opt/crush && make install
  
  # 4. Set up autologin to Hyprland
  - mkdir -p /etc/systemd/system/getty@tty1.service.d
  - |
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOL
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
    EOL
  - systemctl daemon-reload
  
  # 5. Set up .bash_profile to auto-start Hyprland
  - |
    echo '
    if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
      exec Hyprland
    fi' >> /home/${USERNAME}/.bash_profile
  - chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile
EOF

# --- Conditionally add the SSH key (v17 Fix) ---
# This anchors to the 'shell' line, placing the key *inside* the 'user' block.
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

log "Setting machine type to q35..."
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

# --- v17 FIX: Corrected variable $VMID ---
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
log "VM is booting. This version (v17) fixes the serial port and uses the correct 'networkd' renderer."
log "The 125s network timeout should be GONE."
log "Watch with: qm terminal $VMID"
log "This should now connect. You will see a long pause during 'modules:config' as pacman runs."