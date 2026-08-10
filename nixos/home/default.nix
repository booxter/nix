{ pkgs, ... }:
{
  system.stateVersion = "26.05";

  host.network = {
    macAddress = "02:48:4f:4d:45:01";
    reservation = {
      enable = true;
      address = "192.168.20.6";
    };
  };

  _module.args.homeAssistantTools = pkgs.callPackage ./pkgs/home-assistant-tools { };

  imports = [
    ./backup.nix
    ./home-assistant.nix
  ];
}
