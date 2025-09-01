{
  pkgs,
  ...
}:
{
  programs.sketchybar = {
    enable = true;
    config = {
      source = ./sketchybar;
      recursive = true;
    };
    service.enable = false;
    extraPackages = with pkgs; [
      aerospace
      gnugrep
      curl
    ];
  };
}
