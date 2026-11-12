{
  atomicFileWrites,
  lib,
  python3,
  pythonRuffCheckHook,
}:
python3.pkgs.buildPythonApplication {
  pname = "letterboxd-sync";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  dependencies = with python3.pkgs; [
    atomicFileWrites
    beautifulsoup4
    curl-cffi
    jellyfin-apiclient-python
    pydantic
  ];

  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/letterboxd_sync
  '';

  pythonImportsCheck = [ "letterboxd_sync" ];

  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Copy Jellyfin watched movies to Letterboxd";
    mainProgram = "letterboxd-sync";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
