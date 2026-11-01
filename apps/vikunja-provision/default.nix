{
  age,
  declarations ? { },
  lib,
  python3,
  pythonRuffCheckHook,
  sops,
  sopsTools,
}:
let
  pythonPackages = python3.pkgs;
  declarationsFile = builtins.toFile "vikunja-bots.json" (builtins.toJSON declarations);
in
pythonPackages.buildPythonApplication {
  pname = "vikunja-provision";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    pythonPackages.authlib
    pythonPackages.httpx2
    pythonPackages.pydantic
    sopsTools
  ];

  nativeCheckInputs = [
    age
    sops
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/vikunja_provision
  '';

  pythonImportsCheck = [ "vikunja_provision" ];

  makeWrapperArgs = [
    "--set VIKUNJA_DECLARATIONS_FILE ${declarationsFile}"
    "--prefix PATH : ${sopsTools.runtimePath}"
  ];

  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Reconcile Vikunja bots, project access, and MCP tokens";
    license = lib.licenses.mit;
    mainProgram = "vikunja-provision";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
