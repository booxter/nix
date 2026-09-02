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
  pname = "bazarr-auth-config";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.ruamel-yaml
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/bazarr_auth_config
  '';

  pythonImportsCheck = [ "bazarr_auth_config" ];

  meta = {
    description = "Disable Bazarr's local authentication settings";
    license = lib.licenses.mit;
    mainProgram = "enforce-bazarr-auth-config";
    platforms = lib.platforms.linux;
  };
}
