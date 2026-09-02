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
  pname = "watchstate-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    atomicFileWrites
    bcrypt
    podman
    pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/watchstate_tools
  '';

  pythonImportsCheck = [ "watchstate_tools" ];

  meta = {
    description = "Render authentication and back up WatchState";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
