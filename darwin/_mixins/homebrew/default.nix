{
  config,
  inputs,
  lib,
  username,
  ...
}:
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
    greedyCasks = true;
    onActivation = {
      autoUpdate = false;
      upgrade = true;
      # Use pinned local taps because our pinned brew can lag behind
      # Homebrew's API schema for casks.
      extraEnv.HOMEBREW_NO_INSTALL_FROM_API = "1";
    };
    taps = builtins.attrNames config.nix-homebrew.taps;
    casks = [
      "sf-symbols"
      "wireshark-chmodbpf"
    ];
  };

  nix-homebrew = {
    enable = true;
    mutableTaps = false;
    user = username;
    taps = {
      "homebrew/homebrew-core" = inputs.homebrew-core;
      "homebrew/homebrew-cask" = inputs.homebrew-cask;
    };
  };
}
