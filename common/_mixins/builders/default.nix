{
  config,
  hostSpec,
  isLinux,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      hostSpec
      lib
      outputs
      ;
  };
  builderType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Fleet name of the builder.";
      };
      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SSH hostname advertised by the builder.";
      };
      systems = lib.mkOption {
        type = with lib.types; nonEmptyListOf nonEmptyStr;
        description = "Nix systems supported by the builder.";
      };
      maxJobs = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Maximum concurrent builds accepted by the builder.";
      };
      speedFactor = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Relative scheduling preference for the builder.";
      };
      supportedFeatures = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        description = "Nix system features supported by the builder.";
      };
    };
  };
in
{
  imports = [
    ./assertions.nix
    ./community.nix
    ./realm.nix
  ];

  options.host.nix = {
    builder = {
      enable = lib.mkEnableOption "Nix builder participation";

      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = hostSpec.name;
        description = "SSH hostname advertised to builder clients.";
      };

      maxJobs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Maximum concurrent builds accepted from remote clients.";
      };

      speedFactor = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100;
        description = "Relative scheduling preference advertised to builder clients.";
      };

      supportedFeatures = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [
          "benchmark"
          "big-parallel"
          "kvm"
          "nixos-test"
        ]
        ++ lib.optionals isLinux [
          "devnet"
          "uid-range"
        ];
        description = "Nix system features advertised to builder clients.";
      };
    };

    builder-pool = lib.mkOption {
      type = lib.types.listOf builderType;
      default = model.builderPool;
      readOnly = true;
      internal = true;
      description = "Enabled builders in this host's realm, excluding the host itself.";
    };
  };

  options.host = {
    nixpkgsReview.extraBuilders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Review-only Nix builders in machines-file format.";
    };
  };
}
