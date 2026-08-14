{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  useType = lib.types.enum [
    "build"
    "nixpkgs"
  ];
  builderOptions = {
    uses = lib.mkOption {
      type = lib.types.nonEmptyListOf useType;
      description = "Consumers allowed to use the builder.";
    };
    hostName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Network hostname of the builder.";
    };
    protocol = lib.mkOption {
      type = lib.types.enum [
        "ssh"
        "ssh-ng"
      ];
      default = "ssh";
      description = "Nix store protocol used to reach the builder.";
    };
    sshKey = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "SSH identity file used to authenticate to the builder.";
    };
    sshUser = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "SSH user used to reach the builder.";
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
  builderType = lib.types.submodule {
    options = builderOptions;
  };
  externalBuilderType = lib.types.submodule {
    options = builderOptions // {
      publicKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SSH host public key of the builder.";
      };
    };
  };
in
{
  imports = [
    ./assertions.nix
    ./community.nix
    ./build.nix
    ./home.nix
    ./nixpkgs-review.nix
    ./ssh.nix
    ./work.nix
  ];

  options.host.nix = {
    builder = {
      enable = lib.mkEnableOption "Nix builder participation";

      sshIdentityFileName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SSH identity file name used to authenticate to builders in this realm.";
      };

      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = config.networking.hostName;
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
        ++ lib.optionals config.nixpkgs.hostPlatform.isLinux [
          "devnet"
          "uid-range"
        ];
        description = "Nix system features advertised to builder clients.";
      };

      uses = lib.mkOption {
        type = lib.types.nonEmptyListOf useType;
        default = [
          "build"
          "nixpkgs"
        ];
        description = "Consumers allowed to use this builder.";
      };
    };

    external-builders = lib.mkOption {
      type = lib.types.attrsOf externalBuilderType;
      default = { };
      description = "Builders not managed by this flake that are available to this host.";
    };

    builder-pool = lib.mkOption {
      type = lib.types.attrsOf builderType;
      default = model.builderPool;
      readOnly = true;
      internal = true;
      description = "Normalized builders available to this host, excluding the host itself.";
    };
  };
}
