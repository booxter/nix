{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.dockerDesktop;
  jsonFormat = pkgs.formats.json { };
  registry = jsonFormat.generate "docker-desktop-registry.json" {
    allowedOrgs = [ "nvidia" ];
  };
in
{
  options.host.dockerDesktop.enable = lib.mkEnableOption "Docker Desktop";

  config = lib.mkMerge [
    { host.dockerDesktop.enable = lib.mkDefault (config.host.realm == "work"); }
    (lib.mkIf cfg.enable {
      homebrew.casks = [ "docker-desktop" ];

      system.activationScripts.preActivation.text = ''
        docker_desktop_config_dir="/Library/Application Support/com.docker.docker"
        /usr/bin/install -d -m 0755 -o root -g admin "$docker_desktop_config_dir"
        /usr/bin/install -m 0644 -o root -g admin ${registry} "$docker_desktop_config_dir/registry.json"
      '';
    })
  ];
}
