{
  lib,
  python3,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/uptimerobot_sync
  '';

  pythonImportsCheck = [ "uptimerobot_sync" ];

  meta = {
    description = "Sync UptimeRobot monitors from Nix service inventory";
    license = lib.licenses.mit;
    mainProgram = "uptimerobot-sync";
    platforms = lib.platforms.linux;
  };
}
