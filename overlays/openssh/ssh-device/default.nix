{
  lib,
  python3,
  pythonRuffCheckHook,
  yubikey-manager,
  identities,
  openssh,
}:
let
  manifest = builtins.toFile "ssh-device-identities.json" (builtins.toJSON identities);
in
python3.pkgs.buildPythonApplication {
  pname = "ssh-device";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3.pkgs.setuptools ];
  dependencies = [
    python3.pkgs.pydantic
    yubikey-manager
  ];
  nativeCheckInputs = with python3.pkgs; [
    openssh
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];
  __darwinAllowLocalNetworking = true;
  preCheck = ''
    mypy src/ssh_device
  '';
  makeWrapperArgs = [
    "--add-flags '--identities ${manifest}'"
    "--prefix PATH : ${lib.makeBinPath [ openssh ]}"
  ];
  pythonImportsCheck = [ "ssh_device" ];
  meta = {
    description = "Resolve SSH identities to connected YubiKeys";
    license = lib.licenses.mit;
    mainProgram = "ssh-device";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
