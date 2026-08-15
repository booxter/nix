{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.env;
  profiles = {
    personal = import ./personal.nix { inherit pkgs; };
    nvidia = import ./nvidia.nix { inherit config; };
  };
  applyDefaults = lib.mapAttrsRecursive (_: value: lib.mkOverride 900 value);
  applyProfile =
    profile:
    lib.mkMerge [
      (applyDefaults profile.base)
      (lib.mkIf cfg.roles.developer (applyDefaults profile.developer))
      (lib.mkIf cfg.roles.workstation (applyDefaults profile.workstation))
    ];
in
{
  imports = [
    ./repositories.nix
    ./smtp.nix
  ];

  options.host.hm.env = {
    flavor = lib.mkOption {
      type = lib.types.enum [
        "nvidia"
        "personal"
      ];
      default = if osConfig.host.realm == "work" then "nvidia" else "personal";
      description = "Identity and policy flavor for the user environment.";
    };

    tier = lib.mkOption {
      type = lib.types.enum [
        "base"
        "developer"
        "workstation"
      ];
      default = if osConfig.host.desktop == null then "base" else "workstation";
      description = "Cumulative user environment tier.";
    };

    roles = {
      developer = lib.mkOption {
        type = lib.types.bool;
        default = lib.elem cfg.tier [
          "developer"
          "workstation"
        ];
        readOnly = true;
        internal = true;
        description = "Whether the developer environment layer is active.";
      };

      workstation = lib.mkOption {
        type = lib.types.bool;
        default = cfg.tier == "workstation";
        readOnly = true;
        internal = true;
        description = "Whether the workstation environment layer is active.";
      };
    };

    homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
  };

  config = lib.mkMerge (
    [
      {
        stylix.enable = cfg.roles.workstation;
        host.hm.env.homerow.enable = lib.mkDefault (
          cfg.roles.workstation && pkgs.stdenv.hostPlatform.isDarwin
        );
      }
    ]
    ++ lib.mapAttrsToList (name: profile: lib.mkIf (cfg.flavor == name) (applyProfile profile)) profiles
  );
}
