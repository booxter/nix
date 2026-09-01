{
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "proxmox-host-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/proxmox_host_tools
  '';

  pythonImportsCheck = [ "proxmox_host_tools" ];

  meta = {
    description = "Host integration tools for Proxmox VE nodes";
    license = lib.licenses.mit;
    mainProgram = "proxmox-install-api-certificate";
    platforms = lib.platforms.linux;
  };
}
