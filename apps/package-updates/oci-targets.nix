let
  root = ../..;
  mkTarget = path: import (root + "/${path}") // { inherit path; };
in
{
  pinepods = mkTarget "nixos/_mixins/pinepods/image-pin.nix";
  pinepods-ai = mkTarget "nixos/_mixins/pinepods/ai-image-pin.nix";
  watchstate = mkTarget "nixos/_mixins/watchstate/image-pin.nix";
}
