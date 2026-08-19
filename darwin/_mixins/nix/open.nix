{ pkgs, ... }:
let
  openWrapper = pkgs.callPackage ./pkgs/nix-store-aware-open { };
in
{
  # Launching an app through a result symlink lets macOS attach a
  # com.apple.macl attribute to the bundle in the Nix store. Nix GC then
  # cannot make the bundle writable for deletion and fails with EPERM. Open a
  # metadata-free cached copy so the immutable store path is never launched.
  # Bug: https://github.com/NixOS/nix/issues/6765
  environment.systemPackages = [ openWrapper ];
}
