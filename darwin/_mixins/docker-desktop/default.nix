{
  config,
  lib,
  pkgs,
  ...
}:
let
  jsonFormat = pkgs.formats.json { };
  registry = jsonFormat.generate "docker-desktop-registry.json" {
    allowedOrgs = [ "nvidia" ];
  };
  configDirectory = "/Library/Application Support/com.docker.docker";
in
{
  config = lib.mkIf (config.host.realm == "work") {
    homebrew.casks = [ "docker-desktop" ];

    system.tmpfiles.settings.docker-desktop.${configDirectory}.d = {
      mode = "0755";
      user = "root";
      group = "admin";
    };

    system.activationScripts.applications.text = lib.mkBefore ''
      /usr/bin/install -m 0644 -o root -g admin ${registry} ${lib.escapeShellArg "${configDirectory}/registry.json"}
    '';
  };
}
