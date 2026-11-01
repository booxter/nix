{
  atomicFileWrites,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "proxmox-bootstrap";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.cryptography
  ];
  nativeCheckInputs = [
    pythonRuffCheckHook
    pythonPackages.bcrypt
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];
  preCheck = ''
    mypy src/proxmox_bootstrap
  '';
  pythonImportsCheck = [ "proxmox_bootstrap.identity" ];

  meta = {
    description = "Validate and stage Proxmox guest installation identities";
    mainProgram = "proxmox-install-identity";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
