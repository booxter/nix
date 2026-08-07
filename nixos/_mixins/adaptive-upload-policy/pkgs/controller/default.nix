{
  atomicFileWrites,
  lib,
  python3,
  ruff,
  transmissionCommon,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "adaptive-upload-controller";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    atomicFileWrites
    httpx
    prometheus-client
    pydantic
    transmissionCommon
  ];

  nativeCheckInputs = [
    ruff
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/adaptive_upload_controller
  '';

  pythonImportsCheck = [ "adaptive_upload_controller" ];

  meta = {
    description = "Adaptive upload policy controller for Jellyfin-aware torrent shaping";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "adaptive-upload-controller";
    platforms = lib.platforms.linux;
  };
}
