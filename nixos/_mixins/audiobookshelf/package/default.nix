{
  lib,
  python3,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/audiobookshelf_tools
  '';

  pythonImportsCheck = [ "audiobookshelf_tools" ];

  meta = {
    description = "Reconcile Audiobookshelf settings and libraries";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
