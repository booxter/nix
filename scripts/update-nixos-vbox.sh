#!/usr/bin/env bash

set -euo pipefail

VM=nixos
VMI_DESTDIR=/Users/Share/VMI
VMI_DESTFILE=$VMI_DESTDIR/$VM.ova

echo "Updating NixOS VirtualBox image..."
make linux-vbox

echo "Copying NixOS VirtualBox image to $VMI_DESTDIR..."
rsync --progress $(realpath ./result/$VM*) $VMI_DESTFILE

echo "Importing NixOS VirtualBox image..."
./scripts/start-nixos-vbox-import.sh

echo "Cleaning up old SSH keys for $VM..."
ssh-keygen -R $VM
