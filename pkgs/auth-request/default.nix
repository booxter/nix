{
  lib,
  python3,
  pythonRuffCheckHook,
}:
python3.pkgs.buildPythonApplication {
  pname = "auth-request";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3.pkgs.setuptools ];
  postPatch = ''
    chmod +x tests/fixtures/*
    patchShebangs --build tests/fixtures
  '';
  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = ''
    mypy src/auth_request
  '';
  pythonImportsCheck = [ "auth_request" ];

  meta = {
    description = "Show authentication activity in SketchyBar";
    license = lib.licenses.mit;
    mainProgram = "auth-request";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
