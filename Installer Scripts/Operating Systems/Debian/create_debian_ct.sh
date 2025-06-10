#!/usr/bin/env bash

# Author: Niicholai Black
# Date: 6/8/2025
# Version: 0.2.2 - Updated 6/10/2025
# License: AGPL-3.0 - https://github.com/niicholai/Proxmox-Magic-Scripts?tab=AGPL-3.0-1-ov-file#readme
# Inspired by: tteckster
# Rest in peace tteck - you helped a lot of people find an easier way to get into self-hosting, including myself.


# === Interactive Proxmox CT creation script to install Debian ===


# --- Load library of functions ---
source ./ct_build_functions.sh


# --- Cleanup on failure ---
trap 'cleanup' SIGINT SIGTERM


function cleanup() {
  echo
  echo "--- Script interrupted: Initiating cleanup ---"

  if [ -n "$CTID" ]; then
    # Check if container with this ID exists on system.
    if pct status "$CTID" &>/dev/null; then
      echo "INFO: Found partially created container $CTID. Removing..."
      pct stop "$CTID"
      pct destroy "$CTID"
      echo "SUCCESS: Cleanup complete."
    else
      echo "INFO: No container with ID $CTID found. No cleanup necessary."
    fi
  else
    echo "INFO: Container ID was not yet defined. No cleanup needed."
  fi

  # Exit with an error code to signal that the script did not finish successfully.
  exit 1
}


# --- Simple and user friendly minimal Setup ---
function run_setup() {
  echo "--- Debian 12 CT Setup ---"
  echo "Press ENTER to accept the default value shown in [brackets]."

  # --- While Loop for Container ID ---
  while [ -z "$CTID" ]; do
    read -r -p "Enter Container ID: " CTID
    if [ -z "$CTID" ]; then
      echo "ERROR: A Container ID is required. Please try again."
    fi
  done

  # --- Accept defaults with ENTER ---
  read -r -p "Enter Hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
  HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

  read -r -p "Enter Storage location [${DEFAULT_STORAGE}]: " STORAGE
  STORAGE=${STORAGE:-$DEFAULT_STORAGE}

  read -r -p "Enter Disk Size in GB [${DEFAULT_DISK_GB}]: " DISK_GB
  DISK_GB=${DISK_GB:-$DEFAUT_DISK_GB}

  read -r -p "Enter RAM in MB[${DEFAULT_RAM_MB}]: " RAM_MB
  RAM_MB=${RAM_MB:-$DEFAULT_RAM_MB}

  read -r -p "Enter CPU cores [${DEFAULT_CORES}]: " CORES
  CORES=${CORES:-$DEFAULT_CORES}

  # --- While loop to confirm root password ---
  while true; do
    read -r -p "Enter Root Password: " -s PASSWORD
    echo
    read -r -p "Confirm Root Password: " -s PASSWORD_CONFIRM
    echo

    # --- Check matching password entries ---
    if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
      # Check if the password is also empty - I do not allow this by default, you can change this here
      if [ -n "$PASSWORD" ]; then
        echo "Password confirmed."
        break
      else
        echo "ERROR: Password cannot be empty. Please try again."
      fi
    else
      echo "ERROR: Passwords do not match. Please try again."
    fi
  done

  read -r -p "Enter MAC Address (optional): " MAC

  # --- Network Configuration ---
  local net_config="name=eth0,bridge=$BRIDGE,ip=dhcp"
  if [ -n "$MAC" ]; then
    net_config+=",mac=$MAC"
  fi
  # shellcheck disable=SC2034
  NETWORK_CONFIG=$net_config

  # --- Execute the build functions
  create_container
  start_container
  update_container
}


# --- Check if running as root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run with sudo."
  exit 1
fi


# --- Default Configuration ---
HOSTNAME="Debian-12"
BRIDGE="vmbr0"
STORAGE="local-lvm"
DISK_GB="10"
CORES="2"
RAM_MB="2048"
# shellcheck disable=SC2034
FEATURES="nesting=1,fuse=1,keyctl=1"
# shellcheck disable=SC2034
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"


# --- Do the work ---
run_setup


# Clear the trap when the script finishes successfully.
trap - SIGINT SIGTERM


echo "--- All Done! ---"