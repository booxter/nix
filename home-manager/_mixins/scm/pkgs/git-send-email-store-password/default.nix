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
  pname = "git-send-email-store-password";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
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
    mypy src/git_send_email_store_password
  '';

  pythonImportsCheck = [ "git_send_email_store_password" ];

  meta = {
    description = "Store the configured Git SMTP password in macOS Keychain";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "git-send-email-store-password";
    platforms = lib.platforms.darwin;
  };
}
