{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg pluginSettings secretNames;
  serviceName = "degoog";
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = lib.genAttrs (map (name: "degoog/${name}") secretNames) (_: {
      owner = serviceName;
      group = serviceName;
      mode = "0400";
      restartUnits = [ "degoog.service" ];
    });

    sops.templates."degoog.env" = {
      owner = serviceName;
      group = serviceName;
      mode = "0400";
      content = ''
        DEGOOG_SETTINGS_PASSWORDS=${config.sops.placeholder."degoog/settings_password"}
      '';
      restartUnits = [ "degoog.service" ];
    };

    sops.templates."degoog-plugin-settings.json" = {
      owner = serviceName;
      group = serviceName;
      mode = "0400";
      content = builtins.toJSON pluginSettings;
      restartUnits = [ "degoog.service" ];
    };
  };
}
