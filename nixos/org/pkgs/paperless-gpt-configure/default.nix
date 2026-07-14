{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "paperless-gpt-configure";
  runtimeInputs = [ python3 ];
  checkPhase = ''
    runHook preCheck
    PAPERLESS_GPT_CONFIGURE_MAIN=${./main.py} ${python3.pkgs.pytest}/bin/pytest -q -p no:cacheprovider ${./test_main.py}
    runHook postCheck
  '';
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Configure Paperless workflows used by paperless-gpt";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "paperless-gpt-configure";
    platforms = lib.platforms.linux;
  };
}
