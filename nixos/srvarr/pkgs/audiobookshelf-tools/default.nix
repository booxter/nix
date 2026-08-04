{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "audiobookshelf-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    httpx
    pydantic
    pystemd
  ];

  nativeCheckInputs = with pythonPackages; [
    mypy
    pytestCheckHook
    pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/audiobookshelf_tools
  '';

  pythonImportsCheck = [ "audiobookshelf_tools" ];

  meta = {
    description = "Reconcile srvarr Audiobookshelf settings";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
