{
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "home-assistant-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    pythonPackages.httpx
    pythonPackages.pydantic
    pythonPackages.websockets
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/home_assistant_tools
  '';

  pythonImportsCheck = [ "home_assistant_tools" ];

  meta = {
    description = "Bootstrap and back up the fleet Home Assistant instance";
    license = lib.licenses.mit;
    mainProgram = "home-assistant-tools";
    platforms = lib.platforms.linux;
  };
}
