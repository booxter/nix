{
  facts,
  pkgs,
}:
let
  mkImage =
    _name: pin:
    pin
    // {
      imageFile = pkgs.dockerTools.pullImage {
        imageName = pin.image;
        imageDigest = pin.digest;
        hash = pin.hash;
        finalImageName = pin.image;
        finalImageTag = pin.tag;
        os = "linux";
        arch = "amd64";
      };
    };
in
builtins.mapAttrs mkImage facts.oci-images
