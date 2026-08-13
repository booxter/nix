{
  lib,
  pin,
}:
{
  image = lib.mkOption {
    type = lib.types.nonEmptyStr;
    default = pin.image;
    description = "OCI image repository.";
  };

  tag = lib.mkOption {
    type = lib.types.nonEmptyStr;
    default = pin.tag;
    description = "OCI image tag.";
  };

  digest = lib.mkOption {
    type = lib.types.strMatching "^sha256:[0-9a-f]{64}$";
    default = pin.digest;
    description = "Registry digest of the pinned OCI image.";
  };

  hash = lib.mkOption {
    type = lib.types.strMatching "^sha256-.+$";
    default = pin.hash;
    description = "Nix fixed-output hash of the pinned OCI image archive.";
  };
}
