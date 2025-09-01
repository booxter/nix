{ ... }:
{
  # Add red borders to windows
  services.jankyborders = {
    enable = true;
    hidpi = true;
    active_color = "glow(0xffFF0000)";
    inactive_color = "0xff000000";
  };
}
