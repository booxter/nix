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

  users.users.vmadmin.home = "/Users/vmadmin";

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.vmadmin = {
      home.stateVersion = "25.11";
      programs.zsh.enable = true;
      programs.starship = {
        enable = true;
        enableZshIntegration = true;
      };
    };
  };

  virtualisation.vmVariant = {
    environment.systemPackages = [ pkgs.hello ];
    environment.etc."fleet-vm-test".text = "nix-darwin VM activation succeeded\n";
  };
}
