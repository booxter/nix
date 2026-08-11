{
  lib,
  pkgs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
in
{
  assertions = [
    {
      assertion = isDarwin != isLinux;
      message = "Facts platform ${system} must identify exactly one supported kernel.";
    }
  ];
}
