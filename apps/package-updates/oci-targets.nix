let
  root = ../..;
  mkTarget = path: import (root + "/${path}") // { inherit path; };
in
{
  paperless-gpt = mkTarget "nixos/_mixins/paperless/gpt-image-pin.nix";
  pinepods = mkTarget "nixos/_mixins/pinepods/image-pin.nix";
  romm = mkTarget "nixos/_mixins/romm/image-pin.nix";
  watchstate = mkTarget "nixos/_mixins/watchstate/image-pin.nix";
}
