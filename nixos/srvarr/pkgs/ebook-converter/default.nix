{
  calibre,
  lib,
  python3,
  writeShellApplication,
}:
let
  sourceDir = ./.;
in
writeShellApplication {
  name = "ebook-converter";
  runtimeInputs = [ calibre ];
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

    mkdir integration
    cd integration
    printf '%s\n' '<html><body><h1>Conversion test</h1></body></html>' > source.html
    ${calibre}/bin/ebook-convert source.html source.mobi >/dev/null
    ${calibre}/bin/ebook-convert source.mobi output.epub >/dev/null
    PYTHONPATH="${sourceDir}" \
      ${python3}/bin/python3 -c \
        'from pathlib import Path; from main import validate_epub; validate_epub(Path("output.epub"))'
    runHook postCheck
  '';

  meta = {
    description = "Convert library MOBI and AZW3 files to EPUB";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ebook-converter";
    platforms = lib.platforms.linux;
  };
}
