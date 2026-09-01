{
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "jellyfin-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    jellyfin-apiclient-python
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
    mypy src/jellyfin_tools
  '';

  pythonImportsCheck = [ "jellyfin_tools" ];

  meta = {
    description = "Back up Jellyfin and gate maintenance on playback";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
