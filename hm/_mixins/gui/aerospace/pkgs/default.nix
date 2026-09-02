{
  aerospace,
  lib,
  python3,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ aerospace ]}"
  ];

  preCheck = ''
    mypy src/aerospace_x11
  '';

  pythonImportsCheck = [ "aerospace_x11" ];

  meta = {
    description = "Route AeroSpace move and resize actions to active X11 windows";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
}
