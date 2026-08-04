{
  ebookConverterCli,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "srvarr-ebook-converter";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = [
    ebookConverterCli
    ruff
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ ebookConverterCli ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/srvarr_ebook_converter
  '';

  postCheck = ''
    mkdir integration
    cd integration
    export XDG_CONFIG_HOME="$TMPDIR/ebook-converter-config"
    printf '%s\n' '<html><body><h1>Conversion test</h1></body></html>' > source.html
    ${lib.getExe ebookConverterCli} source.html source.mobi >/dev/null
    ${lib.getExe ebookConverterCli} source.mobi output.epub >/dev/null
    PYTHONPATH="$out/${python3.sitePackages}:$PYTHONPATH" \
      ${python3}/bin/python3 -c \
        'from pathlib import Path; from srvarr_ebook_converter.app import validate_epub; validate_epub(Path("output.epub"))'
  '';

  pythonImportsCheck = [ "srvarr_ebook_converter" ];

  meta = {
    description = "Convert library MOBI and AZW3 files to EPUB";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ebook-converter";
    platforms = lib.platforms.linux;
  };
}
