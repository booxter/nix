{
  lib,
  python3,
  ruff,
  transmissionCommon,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "transmission-torrent-cleaner";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [
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
    mypy src/transmission_torrent_cleaner
  '';

  pythonImportsCheck = [ "transmission_torrent_cleaner" ];

  meta = {
    description = "Cleanup utility for old high-ratio or over-age non-priority Transmission torrents";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "transmission-torrent-cleaner";
    platforms = lib.platforms.linux;
  };
}
