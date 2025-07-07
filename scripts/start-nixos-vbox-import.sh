#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
	echo "Usage: $0 <vm-name>"
	exit 1
fi
VM=$1

ASUSTOR_HOST="root@lab-nas1.local"
SCRIPT_PATH="/volume1/VMI/start-$VM-vbox.sh"
echo "Dumping script to $SCRIPT_PATH on NAS..."

ssh "$ASUSTOR_HOST" "cat > $SCRIPT_PATH" << 'EOF'
#!/bin/sh
set -ex

VBOX_MANAGE="/opt/VirtualBox/VBoxManage"

VM="$1"
DISK_PATH="/volume1/VMI/$VM.ova"
NET_IFACE="eth1"
MEMORY="2048"
CPUS="2"

# Delete old VM if it exists
echo "Deleting old NixOS VM..."
$VBOX_MANAGE controlvm $VM poweroff || true
$VBOX_MANAGE unregistervm $VM --delete || true

# Create a new VM
$VBOX_MANAGE import $DISK_PATH --vsys=0 --vmname $VM

# Calculate unique MAC address from VM name
MAC=$(echo -n "$VM" | md5sum | cut -c1-12)

# Switch to bridged networking
$VBOX_MANAGE modifyvm $VM --nic1 bridged --bridgeadapter1 $NET_IFACE --macaddress1 $MAC

# Enable EFI
#$VBOX_MANAGE modifyvm $VM --firmware efi

# Enable nested virtualization
$VBOX_MANAGE modifyvm $VM --nested-hw-virt on

# Set OS type
$VBOX_MANAGE modifyvm $VM --os-type Linux_64

# Start the VM
$VBOX_MANAGE startvm $VM --type headless

# Wait for the VM to start
while ! $VBOX_MANAGE showvminfo $VM | grep -q "State:.*running"; do
		sleep 1
done
EOF

# Ensure the script is removed on exit
trap 'ssh "$ASUSTOR_HOST" "rm -f $SCRIPT_PATH"' EXIT

# Make the script executable
ssh "$ASUSTOR_HOST" "chmod +x $SCRIPT_PATH"
echo "Script dumped successfully."

# Run the script on the NAS
echo "Running the script on NAS to start NixOS VM..."
ssh -t "$ASUSTOR_HOST" "$SCRIPT_PATH $VM"
echo "NixOS VM started successfully."

echo "Cleaning up old SSH keys for $VM..."
ssh-keygen -R $VM

# Wait until ssh port is open
while ! nc -z $VM 22; do
		echo "Waiting for SSH port to open on $VM..."
		sleep 2
done

echo "Updating known_hosts for $VM..."
ssh-keyscan -H $VM >> ~/.ssh/known_hosts
