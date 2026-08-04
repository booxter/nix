{
  ffmpeg,
  flac,
  lib,
  python3,
  ruff,
  unflac,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "lidarr-cue-splitter";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.aiopyarr ];

  nativeCheckInputs = [
    ffmpeg
    flac
    ruff
    unflac
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        ffmpeg
        flac
        unflac
      ]
    }"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
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

  pythonImportsCheck = [ "lidarr_cue_splitter" ];

  meta = {
    description = "Split completed Lidarr CUE images and submit their tracks for manual import";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "lidarr-cue-splitter";
    platforms = lib.platforms.linux;
  };
}
