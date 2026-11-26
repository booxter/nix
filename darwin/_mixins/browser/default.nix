{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  firefoxEnabled = config.home-manager.users.${username}.host.hm.firefox.enable;
  defaultbrowser = pkgs.defaultbrowser.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../../../patches/defaultbrowser-select-app-by-path.patch ];
  });
in
{
  config = {
    environment.systemPackages = lib.optionals firefoxEnabled [ defaultbrowser ];

    home-manager.users.${username} =
      { config, lib, ... }:
      let
        logPath = "${config.home.homeDirectory}/Library/Logs/nix-darwin/default-firefox.log";
        setDefaultFirefox = pkgs.writeShellApplication {
          name = "set-default-firefox";
          text = ''
            firefox_app=${lib.escapeShellArg "${config.home.homeDirectory}/${config.targets.darwin.copyApps.directory}/Firefox.app"}
            default_browser=${lib.getExe defaultbrowser}

            # Browser copies share a bundle ID; select the managed app by path.
            if ! "$default_browser" --app "$firefox_app"; then
              # An explicit launch refreshes LaunchServices when another copy is selected.
              echo "Refreshing Firefox URL handling with an explicit background launch..."
              /usr/bin/open -g -a "$firefox_app"
              "$default_browser" --app "$firefox_app"
            fi
          '';
        };
      in
      lib.mkIf config.host.hm.firefox.enable {
        # Add ordering without replacing Home Manager's launch-agent activation code.
        home.activation.setupLaunchAgents = lib.hm.dag.entryAfter [ "copyApps" ] (lib.mkDefault "");

        # LaunchServices needs a graphical session, which fresh headless guests lack.
        launchd.agents.default-firefox = {
          enable = true;
          config = {
            Label = "org.nixos.default-firefox";
            ProgramArguments = [ (lib.getExe setDefaultFirefox) ];
            RunAtLoad = true;
            LimitLoadToSessionType = "Aqua";
            ProcessType = "Background";
            StandardOutPath = logPath;
            StandardErrorPath = logPath;
          };
        };
      };
  };
}
