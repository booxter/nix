{
  aerospace,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "aerospace-x11-aware-actions";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [
    pythonPackages.pyobjc-framework-Cocoa
    pythonPackages.xlib
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ aerospace ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/aerospace_x11
  '';

  pythonImportsCheck = [ "aerospace_x11" ];

  meta = {
    description = "Route AeroSpace move and resize actions to active X11 windows";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.darwin;
  };
}
