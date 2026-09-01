{
  lib,
  paperless-ngx,
  pythonRuffCheckHook,
}:
let
  python = paperless-ngx.python;
  pythonPackages = python.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "paperless-bootstrap";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = [
    paperless-ngx
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/paperless_bootstrap
  '';

  PAPERLESS_SOURCE_DIR = "${paperless-ngx}/lib/paperless-ngx/src";
  PAPERLESS_NLTK_DIR = paperless-ngx.nltkDataDir;

  pythonImportsCheck = [ "paperless_bootstrap" ];

  passthru = { inherit python; };

  meta = {
    description = "Declarative Paperless user and token bootstrap";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
