{ pkgs, ... }:
{
  system.stateVersion = "26.05";

  _module.args.homeAssistantTools = pkgs.callPackage ./pkgs/home-assistant-tools { };

  imports = [
    ./backup.nix
    ./home-assistant.nix
  ];
}
