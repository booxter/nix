{
  atomicFileWrites,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "degoog-settings";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.deepmerge
    pythonPackages.pydantic
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/degoog_settings
  '';

  pythonImportsCheck = [ "degoog_settings" ];

  meta = {
    description = "Merge managed Degoog plugin settings";
    license = lib.licenses.mit;
    mainProgram = "degoog-merge-plugin-settings";
    platforms = lib.platforms.linux;
  };
}
