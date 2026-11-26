{
  lib,
  openssh,
  python3,
  pythonRuffCheckHook,
  approvedKeysFile,
  localIdentityCommand ? null,
}:
python3.pkgs.buildPythonApplication {
  pname = "git-hardware-signing-key";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3.pkgs.setuptools ];
  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = ''
    mypy src/git_hardware_signing_key
  '';
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ openssh ])
    "--add-flag"
    "--approved-keys"
    "--add-flag"
    (toString approvedKeysFile)
  ]
  ++ lib.optionals (localIdentityCommand != null) [
    "--add-flag"
    "--local-identity-command"
    "--add-flag"
    localIdentityCommand
  ];
  pythonImportsCheck = [ "git_hardware_signing_key" ];
  meta = {
    description = "Select an approved hardware identity for Git SSH signing";
    mainProgram = "git-hardware-signing-key";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
