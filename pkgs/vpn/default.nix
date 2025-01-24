# TODO: how to kinit-pass on VPN up?
{ pkgs, ... }: pkgs.writeScriptBin "vpn" ''
  osascript << EOF
    tell application "Viscosity"
    if the state of the first connection is "Connected" then
      disconnect "Red Hat Global VPN"
    else
      connect "Red Hat Global VPN"
    end if
    end tell
  EOF
  ''
