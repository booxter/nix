{
  inputs,
  pkgs,
  ...
}:
{
  jellarr = pkgs.callPackage ./jellarr {
    src = inputs.jellarr;
  };
}
