{ lib, ... }:
{
  imports = [
    ./amd.nix
    ./rocm.nix
  ];

  options.hardware.gpu = {
    vendors = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "amd"
          "intel"
          "nvidia"
        ]
      );
      default = [ ];
      apply =
        vendors:
        let
          unsupported = builtins.filter (vendor: vendor != "amd") vendors;
        in
        if unsupported == [ ] then
          vendors
        else
          throw "GPU support is not implemented for: ${lib.concatStringsSep ", " unsupported}";
      description = "GPU vendors supported by this host.";
    };

    compute = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "rocm" ]);
      default = null;
      description = "GPU compute stack to enable.";
    };
  };
}
