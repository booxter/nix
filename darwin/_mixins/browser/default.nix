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
          # Browser copies share a bundle ID; select the managed app by path.
          run ${lib.getExe defaultbrowser} --app ${lib.escapeShellArg "${config.home.homeDirectory}/${config.targets.darwin.copyApps.directory}/Firefox.app"}
        '';
      };
  };
}
