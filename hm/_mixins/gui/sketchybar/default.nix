{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.sketchybar;
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  pkiRootCaPath = osConfig.host.pki.authority.rootCaCertificate;
  theme = import ./theme.nix {
    inherit config pkgs;
    height = cfg.height;
  };

  positionRank = {
    left = 0;
    center = 1;
    right = 2;
  };
  namedApplets = lib.mapAttrsToList (name: value: value // { inherit name; }) cfg.internal.applets;
  orderedApplets = lib.sort (
    left: right:
    if positionRank.${left.position} != positionRank.${right.position} then
      positionRank.${left.position} < positionRank.${right.position}
    else if left.order != right.order then
      left.order < right.order
    else
      left.name < right.name
  ) namedApplets;
  appletConfig = pkgs.writeText "sketchybar-items.sh" (
    lib.concatMapStringsSep "\n" (applet: applet.script) orderedApplets
  );
  pluginNames = lib.unique (lib.concatMap (applet: applet.plugins) orderedApplets);
  pluginPackages = lib.mergeAttrsList (map (applet: applet.pluginPackages) orderedApplets);
  extraPackages = lib.unique (lib.concatMap (applet: applet.packages) orderedApplets);

  sketchybarPlugins = import ./pkgs {
    inherit pkgs pluginNames pluginPackages;
    pluginColors = theme.pluginEnvironment;
    alertmanager = lib.optionalAttrs cfg.alertmanager.enable {
      url = cfg.alertmanager.url;
      caCertificate = pkiRootCaPath;
      inherit (cfg.alertmanager) clientCertificate clientKey;
    };
    jellyfin = lib.optionalAttrs cfg.jellyfin.enable {
      inherit (cfg.jellyfin) metricsUrl clientCertificate clientKey;
      caCertificate = pkiRootCaPath;
    };
  };
  sketchybarConfig = pkgs.runCommandLocal "sketchybar-config" { } ''
    ${lib.getExe pkgs.bash} -n ${appletConfig}
    mkdir -p "$out/plugins" "$out/themes"
    cp ${./sketchybar/sketchybarrc} "$out/sketchybarrc"
    ln -s ${theme.file} "$out/themes/gruvbox"
    ln -s ${appletConfig} "$out/items.sh"
    ${lib.concatMapStringsSep "\n" (name: ''
      ln -s ${sketchybarPlugins}/bin/${name} "$out/plugins/${name}.sh"
    '') pluginNames}
  '';
in
{
  imports = [ ./applets ];

  options.host.hm.sketchybar = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = isDarwin;
      description = "Whether to enable Sketchybar.";
    };

    height = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Sketchybar height in pixels.";
    };

    internal.applets = lib.mkOption {
      internal = true;
      default = { };
      description = "Enabled Sketchybar applet definitions.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            position = lib.mkOption {
              type = lib.types.enum [
                "left"
                "center"
                "right"
              ];
            };
            order = lib.mkOption { type = lib.types.int; };
            script = lib.mkOption { type = lib.types.lines; };
            plugins = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
              default = [ ];
            };
            pluginPackages = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    package = lib.mkOption { type = lib.types.package; };
                    executable = lib.mkOption { type = lib.types.nonEmptyStr; };
                  };
                }
              );
            };
            packages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isDarwin;
        message = "host.hm.sketchybar is only supported on Darwin.";
      }
    ];

    programs.sketchybar = {
      enable = true;
      config = {
        source = sketchybarConfig;
        recursive = true;
      };
      service.enable = true;
      extraPackages =
        extraPackages
        ++ (with pkgs; [
          gnugrep
          curl
          jq
        ]);
    };
  };
}
