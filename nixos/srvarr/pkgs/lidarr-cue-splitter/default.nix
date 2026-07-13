{
  ffmpeg,
  flac,
  lib,
  python3,
  unflac,
  writeShellApplication,
}:
let
  sourceDir = ./.;
in
writeShellApplication {
  name = "lidarr-cue-splitter";
  runtimeInputs = [
    ffmpeg
    flac
    unflac
  ];
  text = ''
    exec ${python3}/bin/python3 ${./main.py} "$@"
  '';
  derivationArgs = {
    doCheck = true;
  };
  checkPhase = ''
    runHook preCheck
    PYTHONPATH="${sourceDir}" \
      ${python3}/bin/python3 -m unittest discover -s "${sourceDir}" -p 'test_*.py'

    ${ffmpeg}/bin/ffmpeg -hide_banner -decoders 2>&1 | grep -F ' ape '
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
    runHook postCheck
  '';

  meta = {
    description = "Split completed Lidarr CUE images and submit their tracks for manual import";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "lidarr-cue-splitter";
    platforms = lib.platforms.linux;
  };
}
