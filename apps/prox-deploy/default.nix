{
  lib,
  nixmoxer,
  pass,
  python3,
  ruff,
  vmTypes,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "prox-deploy";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ nixmoxer ];

  nativeCheckInputs = [
    ruff
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  makeWrapperArgs = [
    "--set PROX_DEPLOY_PASS ${lib.escapeShellArg (lib.getExe pass)}"
    "--set PROX_DEPLOY_VM_TYPES_JSON ${lib.escapeShellArg (builtins.toJSON vmTypes)}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/prox_deploy
  '';

  pythonImportsCheck = [ "prox_deploy" ];

  meta = {
    description = "Deploy inventory-backed NixOS VMs through nixmoxer";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "prox-deploy";
    platforms = lib.platforms.unix;
  };
}
