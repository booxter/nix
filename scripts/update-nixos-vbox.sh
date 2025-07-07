#!/usr/bin/env bash

set -euo pipefail

VM=nixos
VMI_DESTDIR=/Users/Share/VMI
VMI_DESTFILE=$VMI_DESTDIR/$VM.ova

echo "Updating NixOS VirtualBox image..."
make linux-vbox

echo "Checking if md5sum changed for $VM..."
NEW_MD5=$(md5sum ./result/$VM*.ova | awk '{print $1}')
if [ -e $VMI_DESTFILE -a -e $VMI_DESTFILE.md5sum ]; then
	OLD_MD5=$(cat $VMI_DESTFILE.md5sum)

	if [ "$NEW_MD5" == "$OLD_MD5" ]; then
			echo "No changes detected in VM image. Do nothing."
			exit 0
	fi
fi

echo "Copying NixOS VirtualBox image to $VMI_DESTDIR..."
rsync --progress $(realpath ./result/$VM*) $VMI_DESTFILE
echo $NEW_MD5 > $VMI_DESTFILE.md5sum

echo "Importing NixOS VirtualBox image..."
./scripts/start-nixos-vbox-import.sh

echo "Cleaning up old SSH keys for $VM..."
ssh-keygen -R $VM

# Wait until ssh port is open
while ! nc -z $VM 22; do
		echo "Waiting for SSH port to open on $VM..."
		sleep 2
done

echo "Updating known_hosts for $VM..."
ssh-keyscan -H $VM >> ~/.ssh/known_hosts
