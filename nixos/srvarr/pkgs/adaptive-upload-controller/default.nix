{
  iproute2,
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

  dependencies = [ transmissionCommon ];

  nativeCheckInputs = [ ruff ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ iproute2 ]}"
  ];

  preCheck = ''
    ruff format --check src
    ruff check src
  '';

  pythonImportsCheck = [ "adaptive_upload_controller" ];

  meta = {
    description = "Adaptive upload policy controller for Jellyfin-aware torrent shaping";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "adaptive-upload-controller";
    platforms = lib.platforms.unix;
  };
}
