{
  lib,
  python3,
  transmissionCommon,
  writeShellApplication,
}:
let
  sourceDir = ./.;
  pythonWithDeps = python3.withPackages (_: [
    transmissionCommon
  ]);
  mkTool =
    {
      name,
      script,
      description,
    }:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ pythonWithDeps ];
      text = ''
        export PYTHONPATH="${sourceDir}:''${PYTHONPATH:-}"
        exec ${pythonWithDeps}/bin/python3 ${script} "$@"
      '';
      derivationArgs = {
        doCheck = true;
      };
      checkPhase = ''
        runHook preCheck
        PYTHONPATH="${sourceDir}" \
          ${pythonWithDeps}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'
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
