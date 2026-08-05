{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "jellystat-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    httpx
    pydantic
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
    mypy src/jellystat_tools
  '';

  pythonImportsCheck = [ "jellystat_tools" ];

  meta = {
    description = "Bootstrap and back up the Beast Jellystat service";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
