{
  atomicFileWrites,
  ffmpeg,
  flac,
  hermesRuns,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "arr-post-processor";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    aiohttp
    atomicFileWrites
    aiopyarr
    defusedxml
    hermesRuns
    prometheus-client
    pydantic
  ];

  nativeCheckInputs = [
    ffmpeg
    flac
    pythonRuffCheckHook
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  ARR_POST_PROCESSOR_FFPROBE = lib.getExe' ffmpeg "ffprobe";
  ARR_POST_PROCESSOR_FLAC = lib.getExe flac;

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        ffmpeg
        flac
      ]
    }"
    "--set ARR_POST_PROCESSOR_FFPROBE ${lib.getExe' ffmpeg "ffprobe"}"
    "--set ARR_POST_PROCESSOR_FLAC ${lib.getExe flac}"
  ];

  preCheck = ''
    mypy src/arr_post_processor
  '';

  pythonImportsCheck = [ "arr_post_processor" ];

  meta = {
    description = "Queue-aware post-processing service for Servarr applications";
    license = lib.licenses.mit;
    mainProgram = "arr-post-processor";
    platforms = lib.platforms.linux;
  };
}
