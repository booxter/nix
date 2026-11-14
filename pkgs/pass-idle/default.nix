{
  atomic-file-writes,
  lib,
  python3,
  pythonRuffCheckHook,
}:
python3.pkgs.buildPythonApplication {
  pname = "pass-idle";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3.pkgs.setuptools ];
  dependencies = [ atomic-file-writes ];

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
    mypy src/pass_idle
  '';
  pythonImportsCheck = [ "pass_idle" ];

  meta = {
    description = "Reset GnuPG authorization after password-store inactivity";
    license = lib.licenses.mit;
    mainProgram = "pass-idle";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
