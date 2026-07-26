{
  fetchFromGitHub,
  lib,
  python313Packages,
}:

python313Packages.buildPythonApplication {
  pname = "ebook-converter";
  version = "4.12.0-unstable-2026-05-13";
  pyproject = true;

  # Upstream publishes neither tags nor releases. The update script follows
  # master while this source remains pinned for reproducible builds.
  src = fetchFromGitHub {
    owner = "gryf";
    repo = "ebook-converter";
    rev = "fa24530bc5d47f5f1d680c9410fb24e311f2bb83";
    hash = "sha256-8Ud8ZBl7sJwSkNgO9SJPd9V0n202pdDVAHskSZjqm/Y=";
  };

  build-system = [ python313Packages.setuptools ];

  dependencies = with python313Packages; [
    beautifulsoup4
    css-parser
    filelock
    html2text
    html5-parser
    msgpack
    odfpy
    pillow
    python-dateutil
    setuptools
    tinycss
  ];

  pythonImportsCheck = [ "ebook_converter" ];

  passthru.updateScript = [ ./update.sh ];

  meta = {
    description = "Command-line converter for common ebook formats";
    homepage = "https://github.com/gryf/ebook-converter";
    changelog = "https://github.com/gryf/ebook-converter/commits/master";
    license = lib.licenses.gpl3Plus;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ebook-converter";
    platforms = lib.platforms.linux;
  };
}
