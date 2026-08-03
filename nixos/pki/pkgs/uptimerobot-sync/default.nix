{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "uptimerobot-sync";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    httpx
    pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/uptimerobot_sync
  '';

  pythonImportsCheck = [ "uptimerobot_sync" ];

  meta = {
    description = "Sync UptimeRobot monitors from Nix service inventory";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "uptimerobot-sync";
    platforms = lib.platforms.linux;
  };
}
