{
  lib,
  nix,
  nixmoxer,
  openssh,
  pass,
  proxmox-bootstrap,
  python3,
  pythonRuffCheckHook,
  vmSpecs,
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
  dependencies = [
    nixmoxer
    proxmox-bootstrap
    pythonPackages.pydantic
  ];

  nativeCheckInputs = [
    pythonRuffCheckHook
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ nix ]}"
    "--set PROX_DEPLOY_PASS ${lib.escapeShellArg (lib.getExe pass)}"
    "--set PROX_DEPLOY_SSH ${lib.escapeShellArg (lib.getExe openssh)}"
    "--set PROX_DEPLOY_VM_SPECS_JSON ${lib.escapeShellArg (builtins.toJSON vmSpecs)}"
  ];

  preCheck = ''
    mypy src/prox_deploy
  '';

  pythonImportsCheck = [ "prox_deploy" ];

  meta = {
    description = "Deploy cluster-backed NixOS VMs through nixmoxer";
    license = lib.licenses.mit;
    mainProgram = "prox-deploy";
    platforms = lib.platforms.unix;
  };
}
