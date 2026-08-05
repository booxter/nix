{
  lib,
  python314,
  ruff,
}:
let
  pythonPackages = python314.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "telegram-archive-service-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    pythonPackages.pydantic
    pythonPackages.pystemd
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
    mypy src/telegram_archive_service_tools
  '';

  pythonImportsCheck = [ "telegram_archive_service_tools" ];

  meta = {
    description = "Host integration tools for Telegram Archive";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "telegram-archive-auth";
    platforms = lib.platforms.linux;
  };
}
