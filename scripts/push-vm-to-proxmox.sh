#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
		echo "Usage: $0 <proxmox-host> <proxmox-user> <pass-ref> <vm-name>"
		exit 1
fi

host="$1"
user="$2"
password=$(pass "$3")
vm_name="$4"

CONFIG_FILE="nixmoxer.conf"

trap 'rm -f "$CONFIG_FILE"' EXIT

{
	echo "host=$host:8006"
	echo "user=$user@pam"
	echo "password=$password"
	echo "verify_ssl=0"
} > "$CONFIG_FILE"

nix run \
	--option extra-trusted-public-keys "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=" \
	--option extra-substituters https://cache.saumon.network/proxmox-nixos \
	github:booxter/proxmox-nixos/vmid-fix#nixmoxer -- --flake "$vm_name"
