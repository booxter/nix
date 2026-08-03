{
  gallery-dl,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "get-ff-cookie";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ gallery-dl ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ gallery-dl ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/get_ff_cookie
  '';

  pythonImportsCheck = [ "get_ff_cookie" ];

  meta = {
    description = "Export Firefox cookies in Netscape format";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "get-ff-cookie";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
