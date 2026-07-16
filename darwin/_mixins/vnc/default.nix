{ lib, username, ... }:
let
  kickstart = "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart";
in
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    echo "Configuring Apple Remote Management for ${username}."

    # Avoid legacy VNC password authentication. Screen Sharing.app can use the
    # local macOS account through Apple Remote Management instead.
    ${kickstart} -configure -access -off
    ${kickstart} -configure -allowAccessFor -specifiedUsers
    ${kickstart} \
      -activate \
      -configure \
      -users ${lib.escapeShellArg username} \
      -access -on \
      -privs -ControlObserve \
      -restart -agent
  '';
}
