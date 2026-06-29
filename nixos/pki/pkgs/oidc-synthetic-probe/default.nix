{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "oidc-synthetic-probe";
  runtimeInputs = [ python3 ];
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
