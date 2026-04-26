{ lib, username, ... }:
{
  system.activationScripts.preActivation.text = lib.mkBefore ''
    if [ -x /usr/bin/xcodebuild ] && [ -x /usr/bin/xcode-select ]; then
      dev_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
      case "$dev_dir" in
        */Xcode.app/Contents/Developer)
          if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
            echo "Accepting Xcode license..."
            /usr/bin/xcodebuild -license accept
          fi
          ;;
      esac
    fi
  '';

  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "docker-desktop"
      "element"
      "openvpn-connect"
      "sf-symbols"
      "spotify" # spotify can't keep its shit together with hashes
      "wireshark-chmodbpf"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = username;
  };
}
