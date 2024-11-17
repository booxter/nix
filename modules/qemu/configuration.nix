{ config, lib, pkgs, ... }: {
  users.users = {
    ihrachys = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      password = "";
    };
  };

  environment.systemPackages = with pkgs; [
    python311
  ];

  system.stateVersion = "24.11";
}
