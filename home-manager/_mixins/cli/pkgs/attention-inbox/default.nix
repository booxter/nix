{
  glab,
  lib,
  python3,
  writeShellApplication,
}:
let
  sourceDir = ./.;
in
writeShellApplication {
  name = "attention-inbox";
  runtimeInputs = [ glab ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  derivationArgs.doCheck = true;
  checkPhase = ''
    runHook preCheck
    PYTHONPATH="${sourceDir}" \
      ${python3}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'
    runHook postCheck
  '';

  meta = {
    description = "Collect attention items from external services into one inbox";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "attention-inbox";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
