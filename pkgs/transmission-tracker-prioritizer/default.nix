{
  lib,
  python3,
  writeShellApplication,
}:
let
  sourceDir = ./.;
  mkTool =
    {
      name,
      script,
      description,
    }:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ python3 ];
      text = ''
        export PYTHONPATH="${sourceDir}:''${PYTHONPATH:-}"
        exec ${python3}/bin/python3 ${script} "$@"
      '';

      meta = {
        inherit description;
        license = lib.licenses.mit;
        maintainers = with lib.maintainers; [ booxter ];
        mainProgram = name;
        platforms = lib.platforms.linux;
      };
    };
in
{
  prioritizer = mkTool {
    name = "transmission-tracker-prioritizer";
    script = ./prioritizer.py;
    description = "Continuously enforce Transmission bandwidth priority for torrents based on selected tracker hosts";
  };

  collector = mkTool {
    name = "transmission-tracker-prioritizer-collector";
    script = ./collector.py;
    description = "Continuously collect Transmission torrent priority metrics based on selected tracker hosts";
  };
}
