{
  lib,
  python3,
  pythonRuffCheckHook,
  makeWrapper,
  gpclient,
  interface,
  portalFile,
  port,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "gpconnect";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.psutil ];
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.types-psutil
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/gpconnect
  '';

  postFixup = ''
    wrapProgram "$out/bin/gpconnect" \
      --set GPCONNECT_CLIENT ${lib.escapeShellArg (lib.getExe' gpclient "gpclient")} \
      --set GPCONNECT_INTERFACE ${lib.escapeShellArg interface} \
      --set GPCONNECT_PORTAL_FILE ${lib.escapeShellArg portalFile} \
      --set GPCONNECT_PORT ${toString port}
  '';

  pythonImportsCheck = [ "gpconnect" ];

  meta = {
    description = "Headless GlobalProtect browser authentication on nv";
    license = lib.licenses.mit;
    mainProgram = "gpconnect";
    platforms = lib.platforms.linux;
  };
}
