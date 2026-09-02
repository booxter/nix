{
  atomicFileWrites,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "auto-upgrade-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.prometheus-client
    pythonPackages.pydantic
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/auto_upgrade_tools
  '';

  pythonImportsCheck = [ "auto_upgrade_tools" ];

  meta = {
    description = "NixOS auto-upgrade hold, metrics, and reboot helpers";
    license = lib.licenses.mit;
    mainProgram = "auto-upgrade-tools";
    platforms = lib.platforms.linux;
  };
}
