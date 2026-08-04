{
  lib,
  python3,
  ruff,
  transmissionCommon,
}:
let
  pythonPackages = python3.pkgs;
  application = pythonPackages.buildPythonApplication {
    pname = "transmission-tracker-prioritizer";
    version = "0.1.0";
    pyproject = true;

    src = ./.;

    build-system = [ pythonPackages.setuptools ];

    dependencies = [
      pythonPackages.prometheus-client
      pythonPackages.pydantic
      transmissionCommon
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
      mypy src/transmission_tracker_prioritizer
    '';

    pythonImportsCheck = [ "transmission_tracker_prioritizer" ];

    meta = {
      description = "Transmission priority enforcement and metrics collection";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [ booxter ];
      platforms = lib.platforms.linux;
    };
  };
  withMainProgram =
    mainProgram:
    application
    // {
      meta = application.meta // {
        inherit mainProgram;
      };
    };
in
{
  prioritizer = withMainProgram "transmission-prioritizer";
  collector = withMainProgram "transmission-collector";
}
