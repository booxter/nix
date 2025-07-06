#!/usr/bin/env bash
set -xe

ASUSTOR_HOST="root@lab-nas1.local"
SCRIPT_PATH="/volume1/VMI/start-nixos-vbox.sh"
echo "Dumping script to $SCRIPT_PATH on NAS..."

ssh "$ASUSTOR_HOST" "cat > $SCRIPT_PATH" << 'EOF'
#!/bin/sh

OS="nixos"
DISK_PATH="/volume1/VMI/$OS.ova"

VBOX_MANAGE="/opt/VirtualBox/VBoxManage"

NET_IFACE="eth1"
MEMORY="2048"
CPUS="2"

# Delete old VM if it exists
$VBOX_MANAGE list vms | grep -q nixos && \
		echo "Deleting old NixOS VM..." && \
		$VBOX_MANAGE controlvm nixos poweroff && \
		$VBOX_MANAGE unregistervm nixos --delete

# Create a new VM
$VBOX_MANAGE import $DISK_PATH --vsys=0 --vmname nixos

# Switch to bridged networking
$VBOX_MANAGE modifyvm nixos --nic1 bridged --bridgeadapter1 $NET_IFACE --macaddress1 deadbeef0001

# Enable EFI
#$VBOX_MANAGE modifyvm nixos --firmware efi

# Enable nested virtualization
$VBOX_MANAGE modifyvm nixos --nested-hw-virt on

# Set OS type
$VBOX_MANAGE modifyvm nixos --os-type Linux_64

# Enable auto-start
$VBOX_MANAGE modifyvm nixos --autostart-enabled on

# Start the VM
$VBOX_MANAGE startvm nixos --type headless

# Wait for the VM to start
while ! $VBOX_MANAGE showvminfo nixos | grep -q "State:.*running"; do
		sleep 1
done
EOF

echo "Script dumped successfully."
# Make the script executable
ssh "$ASUSTOR_HOST" "chmod +x $SCRIPT_PATH"

# Run the script on the NAS
# This will start the NixOS VM in VirtualBox on the NAS
echo "Running the script on NAS to start NixOS VM..."
ssh -t "$ASUSTOR_HOST" "$SCRIPT_PATH"
echo "NixOS VM started successfully."

# Clean up the script from the NAS
echo "Cleaning up the script from NAS..."
ssh "$ASUSTOR_HOST" "rm $SCRIPT_PATH"
echo "Script cleaned up successfully."
