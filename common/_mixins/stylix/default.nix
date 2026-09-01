{
  config,
  inputs,
  pkgs,
  ...
}:
{
  stylix = {
    enable = config.host.desktop != null;
    # Read the scheme from a source input so evaluation does not require IFD.
    base16Scheme = "${inputs.stylix.inputs.tinted-schemes}/base16/gruvbox-dark-hard.yaml";
    polarity = "dark";

    fonts = {
      monospace = {
        package = pkgs.nerd-fonts.meslo-lg;
        name = "MesloLGS Nerd Font Mono";
      };
      sizes.terminal = 14;
    };
  };
}
