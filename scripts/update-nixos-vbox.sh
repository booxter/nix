#!/usr/bin/env bash

set -euo pipefail

# Support -f option to force update
FORCE=0
while getopts "f" opt; do
	case $opt in
		f)
			echo "Forcing update..."
			FORCE=1
			shift
			;;
	esac
done

if [ $# -eq 1 ]; then
	VM=$1
else
	echo "Usage: $0 <vm-name>"
	exit 1
fi

VMI_DESTDIR=/Users/Share/VMI
VMI_DESTFILE=$VMI_DESTDIR/$VM.ova

echo "Updating NixOS VirtualBox image..."
make $VM-vbox

echo "Checking if md5sum changed for $VM..."
NEW_MD5=$(md5sum ./result/nixos*.ova | awk '{print $1}')
if [ -e $VMI_DESTFILE -a -e $VMI_DESTFILE.md5sum ] && [ $FORCE -eq 0 ]; then
	OLD_MD5=$(cat $VMI_DESTFILE.md5sum)

	if [ "$NEW_MD5" == "$OLD_MD5" ]; then
			echo "No changes detected in VM image. Do nothing."
			exit 0
	fi
fi

echo "Copying NixOS VirtualBox image to $VMI_DESTDIR..."
rsync --progress $(realpath ./result/nixos*.ova) $VMI_DESTFILE

echo "Importing NixOS VirtualBox image..."
./scripts/start-nixos-vbox-import.sh $VM

echo $NEW_MD5 > $VMI_DESTFILE.md5sum
