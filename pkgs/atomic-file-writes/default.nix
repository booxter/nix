{
  lib,
  python,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "atomic-file-writes";
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
    mypy src/atomic_file_writes
  '';

  pythonImportsCheck = [ "atomic_file_writes" ];

  meta = {
    description = "Typed durable atomic file replacement helpers";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
