{
  hostname,
  lib,
  pkgs,
  username,
  platform,
  stateVersion,
  isWork,
  ci ? false,
  ...
}:
{
  imports =
    lib.optionals (builtins.pathExists ./${hostname}) [
      ./${hostname}
    ]
    ++ [
      ./_mixins/defaults
      ./_mixins/fonts
      ./_mixins/homebrew
      (import ./_mixins/linux-builder { inherit lib ci; })
      ./_mixins/nix-gc
      ./_mixins/sudo
    ]
    ++ lib.optionals (!isWork) [
      ./_mixins/browser
    ];

  nixpkgs.hostPlatform = lib.mkDefault platform;

  system.stateVersion = stateVersion;

  system.primaryUser = username;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  # Can't configure networking on managed work devices
  networking = lib.optionalAttrs (!isWork) {
    knownNetworkServices =
      # mair - laptop - doesn't have builtin ethernet
      lib.optionals (hostname != "mair") [
        "Ethernet"
      ]
      ++ [
        "Wi-Fi"
      ];
    dhcpClientId = hostname;
  };

  system = {
    activationScripts.postActivation.text = ''
      echo "Do not sleep when on AC power."
      pmset -c sleep 0 # Needs testing - UI not immediately updated.

      echo "Prefer network over sleep."
      pmset networkoversleep 1
    '';
  };

  # To trigger manually,
  # sudo launchctl kickstart -k system/org.nixos.nix-auto-upgrade
  launchd.daemons.nix-auto-upgrade = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.nix}/bin/nix"
        "run"
        "nix-darwin"
        "--"
        "switch"
        "--flake"
        "github:booxter/nix#${hostname}"
        "-L"
        "--show-trace"
      ];
      StartCalendarInterval = {
        Weekday = 6; # Saturday
        Hour = 3;
        Minute = 0;
      };
      StandardOutPath = "/var/log/nix-auto-upgrade.log";
      StandardErrorPath = "/var/log/nix-auto-upgrade.log";
    };
  };

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
