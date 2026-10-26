{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  settingsPath = "${cfg.configDir}/settings.json";
  marketplacesPath = "${cfg.configDir}/plugins/known_marketplaces.json";

  # Backport https://github.com/nix-community/home-manager/pull/10031 without
  # replacing the release module. Remove this extension when our HM pin has it.
  # Pin the merger after its atomic-write and permission fixes (#10018).
  upstreamGenerators = builtins.fetchurl {
    url = "https://raw.githubusercontent.com/nix-community/home-manager/0560d64401a6d5370732a69d08bc4a6b135962d9/modules/lib/generators.nix";
    sha256 = "sha256-E/fCLHTqPg26e8hxSa+G3RBPog/aXRkjdpbijVrEQZk=";
  };
  inherit (import upstreamGenerators { inherit lib; }) mkImpureConfigMerger;

  mutableFiles =
    lib.optionalAttrs (cfg.settings != { } || cfg.marketplaces != { }) {
      ${settingsPath} = ''
        if ($dynamic | type) == "object" and ($static | type) == "object" then
          $dynamic * $static
        else
          error("expected JSON objects")
        end
      '';
    }
    // lib.optionalAttrs (cfg.marketplaces != { }) {
      # The release module seeds timestamps in its generated file. Keep its
      # source, but let Claude retain the metadata it has already written.
      ${marketplacesPath} = ''
        ($static | with_entries(.value |= del(.lastUpdated, .autoUpdate))) as $declared |
        ($dynamic * $declared) | reduce ($declared | keys[]) as $name
          (.; .[$name] = {lastUpdated: "1970-01-01T00:00:00Z", autoUpdate: false} + .[$name])
      '';
    };
in
{
  options.programs.claude-code.mutableSettings = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Merge declared settings and marketplaces into writable files at activation.
      Declared values replace saved values; undeclared values and marketplace
      timestamps and auto-update flags are preserved. Removing a declaration
      leaves its saved value. Switching this off requires moving writable files
      aside before activation.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.mutableSettings) {
    # Reuse the native module's generated sources while suppressing its links.
    home.file = lib.mapAttrs (_: _: { enable = lib.mkForce false; }) mutableFiles;

    home.activation.claudeCodeSettings = lib.mkIf (mutableFiles != { }) (
      lib.hm.dag.entryAfter [ "linkGeneration" ] (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            path: jqOperation:
            mkImpureConfigMerger {
              inherit pkgs path jqOperation;
              staticSettings = config.home.file.${path}.source;
              format = "json";
              empty = "{}";
              mode = "600";
            }
          ) mutableFiles
        )
      )
    );
  };
}
