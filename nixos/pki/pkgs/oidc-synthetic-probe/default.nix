{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "oidc-synthetic-probe";
  checkPhase = ''
    runHook preCheck
    cd "$TMPDIR"
    cp ${./test_main.py} test_main.py
    OIDC_SYNTHETIC_PROBE_MAIN=${./main.py} ${python3.pkgs.pytest}/bin/pytest -q -p no:cacheprovider test_main.py
    runHook postCheck
  '';
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Synthetic OIDC and oauth2-proxy probe";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "oidc-synthetic-probe";
  };
}
