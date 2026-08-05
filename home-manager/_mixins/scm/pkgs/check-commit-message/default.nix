{
  git,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "check-commit-message";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
    git
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ git ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/check_commit_message
    export CHECK_COMMIT_MESSAGE_PROGRAM="$out/bin/check-commit-message"
  '';

  pythonImportsCheck = [ "check_commit_message" ];

  meta = {
    description = "Validate the global Git commit message format";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "check-commit-message";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
