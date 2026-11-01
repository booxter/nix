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
  pname = "vikunja-provision";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.authlib
    pythonPackages.httpx2
    pythonPackages.pydantic
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/vikunja_provision
  '';

  pythonImportsCheck = [ "vikunja_provision" ];

  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Reconcile Vikunja bots, project access, and MCP tokens";
    license = lib.licenses.mit;
    mainProgram = "vikunja-provision";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
