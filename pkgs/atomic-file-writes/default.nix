{
  lib,
  python,
  ruff,
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
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/atomic_file_writes
  '';

  pythonImportsCheck = [ "atomic_file_writes" ];

  meta = {
    description = "Typed durable atomic file replacement helpers";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
