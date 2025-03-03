{ pkgs, ... }: pkgs.writeScriptBin "vpn" ''
  # Why the hell it's seventh?.. Is there a way to refer to it by name?..
  osascript << EOF
    tell application "Viscosity"
    if the state of the seventh connection is not "Connected" then
      connect "Red Hat Global VPN"
    end if
    end tell
  EOF

  # Wait for connection to be established
  while [ "$(osascript -e 'tell application "Viscosity" to state of the seventh connection')" != "Connected" ]; do
    echo 'waiting for VPN connection to be established...'
    sleep 1
  done

  ${pkgs.kinit-pass}/bin/kinit-pass
  ''
