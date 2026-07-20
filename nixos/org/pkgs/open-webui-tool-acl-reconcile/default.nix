{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "open-webui-tool-acl-reconcile";
  runtimeInputs = [ python3 ];
  checkPhase = ''
    runHook preCheck
    OPEN_WEBUI_TOOL_ACL_RECONCILE_MAIN=${./main.py} ${python3.pkgs.pytest}/bin/pytest -q -p no:cacheprovider ${./test_main.py}
    runHook postCheck
  '';
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';

  meta = {
    description = "Reconcile an Open WebUI tool server ACL with a group";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "open-webui-tool-acl-reconcile";
    platforms = lib.platforms.linux;
  };
}
