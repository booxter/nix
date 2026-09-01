{
  atomicFileWrites,
  ffmpeg,
  flac,
  hermesRuns,
  lib,
  python3,
  ruff,
  unrar,
  unflac,
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
    hermesRuns
    prometheus-client
    pydantic
    rarfile
  ];

  nativeCheckInputs = [
    ffmpeg
    flac
    ruff
    unrar
    unflac
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  ARR_POST_PROCESSOR_FFPROBE = lib.getExe' ffmpeg "ffprobe";

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        ffmpeg
        flac
        unflac
        unrar
      ]
    }"
    "--set ARR_POST_PROCESSOR_FFPROBE ${lib.getExe' ffmpeg "ffprobe"}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/arr_post_processor
  '';

  postCheck = ''
    mkdir integration
    cd integration
    ${ffmpeg}/bin/ffmpeg -hide_banner -loglevel error \
      -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 2 -c:a flac album.flac
    printf '%s\n' \
      'PERFORMER "Integration Test"' \
      'TITLE "Split Album"' \
      'FILE "album.flac" WAVE' \
      '  TRACK 01 AUDIO' \
      '    TITLE "First"' \
      '    INDEX 01 00:00:00' \
      '  TRACK 02 AUDIO' \
      '    TITLE "Second"' \
      '    INDEX 01 00:01:00' > album.cue
    mkdir output
    ${unflac}/bin/unflac -o output album.cue
    test "$(find output -type f -name '*.flac' | wc -l)" -eq 2
    find output -type f -name '*.flac' -exec ${flac}/bin/flac --silent --test '{}' +
  '';

  pythonImportsCheck = [ "arr_post_processor" ];

  meta = {
    description = "Queue-aware post-processing service for Servarr applications";
    license = lib.licenses.mit;
    mainProgram = "arr-post-processor";
    platforms = lib.platforms.linux;
  };
}
