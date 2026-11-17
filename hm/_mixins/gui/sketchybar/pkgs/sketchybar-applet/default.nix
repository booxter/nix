{
  lib,
  python,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "sketchybar-applet";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/sketchybar_applet
  '';

  pythonImportsCheck = [ "sketchybar_applet" ];

  meta = {
    description = "Typed helpers shared by SketchyBar applets";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
