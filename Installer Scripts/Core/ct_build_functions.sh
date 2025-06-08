#!/usr/bin/env bash

# Author: Niicholai Black
# Date: 6/6/2025
# Inspired by: tteckster
# Rest in peace tteck - you helped a lot of people find an easier way to get into self-hosting, including myself.

# === My simplified Proxmox Build Functions ===
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
    --rootfs "$STORAGE":"$DISK_GB" \
    --net0 "$NETWORK_CONFIG" \
    --password "$PASSWORD" \
    --onboot 1 \
    --features "$FEATURES"

  echo "SUCCESS: Container $CTID was created."
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
