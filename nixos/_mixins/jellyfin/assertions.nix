{
  config,
  lib,
  ...
}:
let
  cfg = config.host.jellyfin;
  libraries = if cfg == null then [ ] else builtins.attrValues cfg.libraries;
  libraryNames = map (library: library.name) libraries;
  libraryPaths = map (library: library.path) libraries;
in
{
  assertions = lib.optionals (cfg != null) [
    {
      assertion = cfg.libraries != { };
      message = "host.jellyfin.libraries must not be empty.";
    }
    {
      assertion = !cfg.backups.enable || cfg.backups.stagingDirectory != null;
      message = "host.jellyfin.backups.stagingDirectory must be set when Jellyfin backups are enabled.";
    }
    {
      assertion = !cfg.web.public.enable || config.host.web.ingress != null;
      message = "Public Jellyfin requires this host to run realm ingress.";
    }
    {
      assertion = builtins.length libraryNames == builtins.length (lib.unique libraryNames);
      message = "host.jellyfin.libraries must use unique display names.";
    }
    {
      assertion = builtins.length libraryPaths == builtins.length (lib.unique libraryPaths);
      message = "host.jellyfin.libraries must use unique paths.";
    }
    {
      assertion = lib.all (
        library: !lib.hasPrefix "/" library.path && !lib.hasInfix ".." library.path
      ) libraries;
      message = "host.jellyfin library paths must be safe relative paths.";
    }
    {
      assertion = lib.all (
        library: library.metadataPolicy != "tmdb-first" || library.kind == "movies"
      ) libraries;
      message = "tmdb-first metadata policy is only defined for movie libraries.";
    }
  ];
}
