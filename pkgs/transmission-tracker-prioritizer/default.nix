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
      derivationArgs = {
        doCheck = true;
      };
      checkPhase = ''
        runHook preCheck
        PYTHONPATH="${sourceDir}" \
          ${python3}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'
        runHook postCheck
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
    name = "transmission-prioritizer";
    script = ./prioritizer.py;
    description = "Continuously enforce Transmission torrent priority based on selected tracker hosts";
  };

  collector = mkTool {
    name = "transmission-collector";
    script = ./collector.py;
    description = "Continuously collect Transmission torrent metrics based on selected tracker hosts";
  };
}
