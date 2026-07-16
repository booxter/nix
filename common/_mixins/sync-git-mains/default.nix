{
  isDesktop,
  lib,
  ...
}:
{
  options.host.syncGitMains = {
    enable = lib.mkEnableOption "periodic fast-forward updates of local Git main branches";

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = [ "~/src" ];
      description = ''
        Directories whose immediate child Git repositories should have their
        local main or master branch fast-forwarded from origin. A leading
        <literal>~/</literal> is expanded at runtime.
      '';
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Seconds between attempts to update the configured repositories.";
    };
  };

  config.host.syncGitMains.enable = lib.mkDefault isDesktop;
}
