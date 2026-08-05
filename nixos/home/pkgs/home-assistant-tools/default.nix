{
  lib,
  python3,
  ruff,
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
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/home_assistant_tools
  '';

  pythonImportsCheck = [ "home_assistant_tools" ];

  meta = {
    description = "Bootstrap and back up the fleet Home Assistant instance";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "home-assistant-tools";
    platforms = lib.platforms.linux;
  };
}
