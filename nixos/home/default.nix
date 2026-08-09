{ pkgs, ... }:
{
  system.stateVersion = "26.05";

  host.network.reservation = {
    enable = true;
    address = "192.168.20.6";
    identifiers = [ "02:48:4f:4d:45:01" ];
  };

  _module.args.homeAssistantTools = pkgs.callPackage ./pkgs/home-assistant-tools { };

  imports = [
    ./backup.nix
    ./home-assistant.nix
  ];
}
