#!/usr/bin/env bash

# Author: Niicholai Black
# Date: 6/8/2025
# Inspired by: tteckster
# Rest in peace tteck - you helped a lot of people find an easier way to get into self-hosting, including myself.

# === A safe and interactive Proxmox CT creation script ===


# --- Load library of functions ---
source ./ct_build_functions.sh


# --- Safety Net: Cleanup on exit ---
trap 'cleanup' SIGINT SIGTERM

function cleanup() {
  # Ask for confirmation before destroying.
  read -r -p "Script interrupted. Destroy partially created container $CTID? (y/n): " confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    echo "Destroying container $CTID..."
    # 'pct stop' will fail if the CT isn't running, so ignore errors with '|| true'
    pct stop "$CTID" || true
    pct destroy "$CTID" || true
    echo "Cleanup complete."
  else
    echo "Skipping cleanup. A partial container may remain."
  fi
  exit 1
}


# --- Check if running as root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run with sudo."
  exit 1
fi


# --- Configuration (edit these to match your system) ---
BRIDGE="vmbr0"
STORAGE="loval-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
Cores="2"
RAM_MB="1024"
FEATURES="nesting=1,fuse=1,keyctl=1"


# --- Ask the user for important details ---
echo "--- Proxmox Debian CT Creator ---"
read -r -p "Enter a new Container ID: " CTID
if [ -z "$CTID" ]; then
  echo "ERROR: Container ID cannot be empty."
  exit 1
fi

read -r -p "Enter a hostname for the container: " HOSTNAME
read -r -p "Enter disk size in GB: " DISK_GB
read -r -p "Enter desired root password: " -s PASSWORD
echo # add a new line after the hidden password prompt


# --- Define the network configuration ---
NETWORK_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp"


# --- Execute the function from our library ---
create_container
start_container
update_container

echo "--- All Done! ---"