{ config, lib, ... }:
let
  directories = map (lib.removeSuffix "/") (
    builtins.attrValues config.host.observability.nodeExporter.textfile.directories
  );
in
{
  options.host.observability.nodeExporter.textfile.directories = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    internal = true;
    description = ''
      Producer-owned directories to scrape. Register a directory only while its
      producer is configured; never register the shared parent directory.
    '';
  };

  config.assertions = [
    {
      assertion = !builtins.elem "/var/lib/prometheus-node-exporter-textfile" directories;
      message = "Textfile producers must register their own directories, not the shared parent.";
    }
    {
      assertion = builtins.length directories == builtins.length (lib.unique directories);
      message = "Each node-exporter textfile directory must have a single owner.";
    }
  ];
}
