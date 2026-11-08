{
  lib,
  python3,
  pythonRuffCheckHook,
  transmissionCommon,
}:
python3.pkgs.buildPythonApplication {
  pname = "transmission-torrent-repair";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3.pkgs.setuptools ];
  dependencies = [
    python3.pkgs.pydantic
    transmissionCommon
  ];

  nativeCheckInputs = [
    python3.pkgs.mypy
    python3.pkgs.pytestCheckHook
    python3.pkgs.pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = ''
    mypy src/transmission_torrent_repair
  '';
  pythonImportsCheck = [ "transmission_torrent_repair" ];

  meta = {
    description = "Verify Transmission torrents reporting corrupt local data";
    license = lib.licenses.mit;
    mainProgram = "transmission-torrent-repair";
    platforms = lib.platforms.linux;
  };
}
