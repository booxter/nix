{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  networking.hostName = "vm-test";
  system.stateVersion = 6;
  system.primaryUser = "vmadmin";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  virtualisation.vmVariant = {
    environment.systemPackages = [ pkgs.hello ];
    environment.etc."fleet-vm-test".text = "nix-darwin VM activation succeeded\n";
  };
}
