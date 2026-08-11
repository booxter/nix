{ config, lib, ... }:
let
  cfg = config.host.backups;
  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  databaseCapture =
    source:
    builtins.elem source.capture.type [
      "sqlite"
      "postgresql"
      "mariadb"
    ];
in
{
  assertions =
    lib.mapAttrsToList (name: source: {
      assertion = builtins.hasAttr source.destination cfg.destinations;
      message = "host.backups.sources.${name} references unknown destination '${source.destination}'";
    }) sources
    ++ lib.mapAttrsToList (name: source: {
      assertion =
        source.paths != [ ]
        || (source.capture.type == "unit" && source.capture.unit.outputPaths != [ ])
        || (source.capture.type == "scheduled" && source.capture.scheduled.outputPaths != [ ])
        || databaseCapture source;
      message = "host.backups.sources.${name} must contribute a path or database capture";
    }) sources
    ++ lib.mapAttrsToList (name: source: {
      assertion = source.capture.type != "unit" || source.capture.unit.service != null;
      message = "host.backups.sources.${name} unit capture requires a service";
    }) sources
    ++ lib.mapAttrsToList (name: source: {
      assertion =
        !databaseCapture source
        || (
          source.capture.database.destinationDir != null
          && (source.capture.type != "sqlite" || source.capture.database.path != null)
        );
      message = "host.backups.sources.${name} database capture is incomplete";
    }) sources;
}
