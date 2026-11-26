{
  lib,
  runCommand,
  writeText,
  jq,
  zip,
}:
{
  plugins,
  url ? "http://127.0.0.1:8181",
}:
let
  releases = map (
    plugin:
    let
      archive = "${plugin.pname}/${plugin.version}.zip";
      metadata = writeText "${plugin.pname}.json" (
        builtins.toJSON {
          guid = plugin.pluginId;
          name = plugin.pluginName;
          description = plugin.meta.description;
          overview = plugin.meta.description;
          owner = "Local builds";
          versions = [
            {
              inherit (plugin) version targetAbi;
              sourceUrl = "${url}/${archive}";
              changelog = "Built from pinned source with Nix.";
              timestamp = "1970-01-01T00:00:01Z";
            }
          ];
        }
      );
    in
    ''
      mkdir -p "$out/${plugin.pname}"
      (
        cd ${plugin}
        zip -X -q "$out/${archive}" ${lib.escapeShellArgs plugin.pluginFiles}
      )
      checksum=$(md5sum "$out/${archive}")
      jq --arg checksum "''${checksum%% *}" \
        '.versions[0].checksum = $checksum' ${metadata} > ${plugin.pname}.json
    ''
  ) plugins;
in
runCommand "jellyfin-plugin-catalogue"
  {
    nativeBuildInputs = [
      jq
      zip
    ];
  }
  ''
    mkdir -p "$out"
    ${lib.concatStringsSep "\n" releases}
    jq -s '.' ${lib.escapeShellArgs (map (plugin: "${plugin.pname}.json") plugins)} \
      < /dev/null > "$out/manifest.json"
  ''
