{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username}.host.hm;
  env = hmConfig.env;

  # Follow Homebrew's headless CLT installation approach.
  # https://github.com/Homebrew/install/blob/8c82c081753d4263da0cfe615ef8d9433425f22b/install.sh#L828-L849
  ensureCommandLineTools = pkgs.writeShellApplication {
    name = "ensure-command-line-tools";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      developer_dir="$(/usr/bin/xcode-select --print-path 2>/dev/null || true)"
      if [[ -n "$developer_dir" && -x "$developer_dir/usr/bin/clang" ]]; then
        exit 0
      fi

      echo "Searching for Apple Command Line Tools..."
      export LC_ALL=C

      # This marker makes CLT available in Apple's software update catalog.
      marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      /usr/bin/touch "$marker"
      trap '/bin/rm -f "$marker"' EXIT

      updates="$(/usr/sbin/softwareupdate --list)"
      label="$(printf '%s\n' "$updates" | /usr/bin/awk '
        /^[[:space:]]*[*] (Label: )?Command Line Tools/ {
          sub(/^[[:space:]]*[*] (Label: )?/, "")
          print
        }
      ' | sort -V | tail -n 1)"

      if [[ -z "$label" ]]; then
        echo "No Apple Command Line Tools package is available for this macOS." >&2
        printf '%s\n' "$updates" >&2
        exit 1
      fi

      echo "Installing $label..."
      /usr/sbin/softwareupdate --install "$label" --agree-to-license
      /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
      /usr/bin/xcrun --find clang
    '';
  };
in
{
  system.activationScripts.preActivation.text = lib.mkBefore ''
    ${lib.getExe ensureCommandLineTools}

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
    greedyCasks = false;
    onActivation = {
      autoUpdate = false;
      upgrade = true;
      # Homebrew upgrades self-updating casks even without --greedy.
      extraEnv.HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS = "1";
      # Use pinned local taps because our pinned brew can lag behind
      # Homebrew's API schema for casks.
      extraEnv.HOMEBREW_NO_INSTALL_FROM_API = "1";
    };
    taps = builtins.attrNames config.nix-homebrew.taps;
    casks = [
      "sf-symbols"
    ]
    ++ lib.optionals hmConfig.protonvpn.enable [
      "protonvpn"
    ]
    ++ lib.optionals env.homerow.enable [
      "homerow"
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
