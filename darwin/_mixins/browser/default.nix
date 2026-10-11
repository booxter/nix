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
    patches = (old.patches or [ ]) ++ [ ./defaultbrowser-app-path.patch ];
  });
in
{
  config = {
    environment.systemPackages = lib.optionals firefoxEnabled [ defaultbrowser ];

    home-manager.users.${username} =
      { config, lib, ... }:
      lib.mkIf config.host.hm.firefox.enable {
        home.activation.defaultFirefox = lib.hm.dag.entryAfter [ "copyApps" ] ''
          firefox_app=${lib.escapeShellArg "${config.home.homeDirectory}/${config.targets.darwin.copyApps.directory}/Firefox.app"}
          default_browser=${lib.getExe defaultbrowser}

          # Browser copies share a bundle ID; select the managed app by path.
          if ! run "$default_browser" --app "$firefox_app"; then
            # The setter can leave another copy selected despite reporting success.
            # An explicit launch refreshes that choice; verify it again afterward.
            echo "Refreshing Firefox URL handling with an explicit background launch..."
            run /usr/bin/open -g -a "$firefox_app"
            run "$default_browser" --app "$firefox_app"
          fi
        '';
      };
  };
}
