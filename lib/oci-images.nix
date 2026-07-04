{ pkgs }:
let
  pins = builtins.fromJSON (builtins.readFile ./oci-images.json);

  mkImage =
    _name: pin:
    let
      ref = "${pin.image}:${pin.tag}";
    in
    pin
    // {
      inherit ref;

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
builtins.mapAttrs mkImage pins
