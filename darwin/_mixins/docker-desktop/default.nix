{ pkgs, ... }:
let
  jsonFormat = pkgs.formats.json { };
  registry = jsonFormat.generate "docker-desktop-registry.json" {
    allowedOrgs = [ "nvidia" ];
  };
in
{
  homebrew.casks = [ "docker-desktop" ];

  system.activationScripts.preActivation.text = ''
    docker_desktop_config_dir="/Library/Application Support/com.docker.docker"
    /usr/bin/install -d -m 0755 -o root -g admin "$docker_desktop_config_dir"
    /usr/bin/install -m 0644 -o root -g admin ${registry} "$docker_desktop_config_dir/registry.json"
  '';
}
