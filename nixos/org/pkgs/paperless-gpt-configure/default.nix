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
    ${python3}/bin/python3 -m py_compile ${./main.py}
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
