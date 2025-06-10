#!/usr/bin/env bash

# Author: Niicholai Black
# Date: 6/6/2025
# Version: 0.3.0 - Updated 6/10/2025
# License: AGPL-3.0 - https://github.com/niicholai/Proxmox-Magic-Scripts?tab=AGPL-3.0-1-ov-file#readme
# Inspired by: tteckster
# Rest in peace tteck - you helped a lot of people find an easier way to get into self-hosting, including myself.


# === Proxmox Build Functions ===
# This script holds the functions to build a container.
# It does not run on it's own; it is used by another script.


# --- Function to create the container ---
# Uses variables that are set by the script that calls it.
function create_container() {
  echo "INFO: Creating container with ID $CTID and hostname $HOSTNAME..."
  echo "INFO: Enabling features: $FEATURES"


  # The 'pct create' command with basic options.
  # I have added '--features "$FEATURES"' to enable nesting, fuse, and keyctl.
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap 512 \
    --rootfs "$STORAGE":"$DISK_GB" \
    --net0 "$NETWORK_CONFIG" \
    --password "$PASSWORD" \
    --onboot 1 \
    --features "$FEATURES" \
    --unprivileged 1

  echo "SUCCESS: Container $CTID was created as an unprivileged container."
}


# --- Function to start the container ---
function start_container() {
  echo "INFO: Starting container $CTID..."
  pct start "$CTID"
  sleep 10
  echo "SUCCESS: Container $CTID is running"
}


# --- Function to update the new container ---
# This runs commands *inside* the container using 'pct exec'.
function update_container() {
  echo "INFO: Updating Debian package lists..."
  pct exec "$CTID" -- apt-get update

  echo "INFO: Upgrading Debian packages..."
  pct exec "$CTID" -- apt-get -y upgrade

  echo "SUCCESS: Container packages are up to date."
}


# --- Function to install Docker and Docker Compose ---
function install_docker() {
  echo "INFO: Installing Docker and Docker Compose..."

  pct exec "$CTID" -- bash -s << 'EOF'
# Abort the script if it fails
set -e

# --- Set up Docker's apt repo ---
apt-get update
apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repo to Apt resources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# --- Install Docker Engine ---
apt-get update

# Install the latest versions of Docker Engine, CLI, containerd, and plugins
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

EOF

  echo "SUCCESS: Docker and Docker Compose installed."
}