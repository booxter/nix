{
  lib,
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "flake-input-update-summary";
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';
  checkPhase = ''
    runHook preCheck

    PYTHONDONTWRITEBYTECODE=1 \
      ${python3}/bin/python3 -m unittest discover -s ${./.} -p test_main.py

    runHook postCheck
  '';

  meta = {
    description = "Generate a revision-linked flake input update summary";
    license = lib.licenses.mit;
    mainProgram = "flake-input-update-summary";
    platforms = lib.platforms.unix;
  };
}
