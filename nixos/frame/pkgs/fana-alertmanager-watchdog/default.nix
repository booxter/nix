{
  lib,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "fana-alertmanager-watchdog";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  dependencies = [ python3.pkgs.python-telegram-bot ];

  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/fana_alertmanager_watchdog
  '';

  pythonImportsCheck = [ "fana_alertmanager_watchdog" ];

  meta = {
    description = "Watch fana Alertmanager readiness and send direct Telegram notifications";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "fana-alertmanager-watchdog";
    platforms = lib.platforms.linux;
  };
}
