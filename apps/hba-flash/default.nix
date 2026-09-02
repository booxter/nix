{
  defaultFirmwareBundle,
  defaultSas3flashBundle,
  lib,
  makeWrapper,
  openssh,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "hba-flash";
  version = "0.2.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/hba_flash
  '';

  pythonImportsCheck = [ "hba_flash" ];

  postFixup = ''
    wrapProgram "$out/bin/hba-flash" \
      --prefix PATH : ${lib.makeBinPath [ openssh ]} \
      --set HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE ${defaultSas3flashBundle} \
      --set HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE ${defaultFirmwareBundle}
  '';

  meta = {
    description = "Preflight and flash the Broadcom HBA on beast";
    license = lib.licenses.mit;
    mainProgram = "hba-flash";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
