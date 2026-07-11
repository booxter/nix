{ pkgs, ... }:
let
  jsonFormat = pkgs.formats.json { };
  adminSettings = jsonFormat.generate "docker-desktop-admin-settings.json" {
    configurationFileVersion = 2;
    disableUpdate = {
      locked = true;
      value = true;
    };
    silentModulesUpdate = {
      locked = true;
      value = false;
    };
  };
  registry = jsonFormat.generate "docker-desktop-registry.json" {
    allowedOrgs = [ "nvidia" ];
  };
in
{
  homebrew.casks = [ "docker-desktop" ];

  system.activationScripts.preActivation.text = ''
    docker_desktop_config_dir="/Library/Application Support/com.docker.docker"
    /usr/bin/install -d -m 0755 -o root -g admin "$docker_desktop_config_dir"
    /usr/bin/install -m 0644 -o root -g admin ${adminSettings} "$docker_desktop_config_dir/admin-settings.json"
    /usr/bin/install -m 0644 -o root -g admin ${registry} "$docker_desktop_config_dir/registry.json"
  '';
}
