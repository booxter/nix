{
  coreutils,
  defaultFirmwareBundle,
  defaultSas3flashBundle,
  findutils,
  gnugrep,
  gnused,
  lib,
  makeWrapper,
  openssh,
  python3,
  ruff,
  shellcheck,
  stdenvNoCC,
  unzip,
  util-linux,
}:
stdenvNoCC.mkDerivation {
  pname = "hba-flash";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    python3
    python3.pkgs.pytest
    ruff
    shellcheck
  ];

  doCheck = true;
  postPatch = ''
    chmod +x tests/fake_command.py
    patchShebangs tests/fake_command.py
  '';

  checkPhase = ''
    runHook preCheck
    shellcheck hba-flash.sh
    ruff format --check tests
    ruff check tests
    pytest -q tests
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 hba-flash.sh "$out/bin/hba-flash"
    wrapProgram "$out/bin/hba-flash" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          findutils
          gnugrep
          gnused
          openssh
          unzip
          util-linux
        ]
      } \
      --set HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE ${defaultSas3flashBundle} \
      --set HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE ${defaultFirmwareBundle}
    runHook postInstall
  '';

  meta = {
    description = "Preflight and flash the Broadcom HBA on beast";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "hba-flash";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
