{
  bash,
  bats,
  coreutils,
  jq,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "kanidm-person-mail-provision";
  runtimeInputs = [
    coreutils
    jq
  ];
  text = builtins.readFile ./kanidm-person-mail-provision.sh;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [ jq ];
  };
  checkPhase = ''
    runHook preCheck
    ${lib.getExe bash} -n "$target"
    ${lib.getExe shellcheck} "$target"
    KANIDM_PERSON_MAIL_PROVISION_BIN=${./kanidm-person-mail-provision.sh} \
      ${lib.getExe bats} --print-output-on-failure ${./kanidm-person-mail-provision.bats}
    runHook postCheck
  '';

  meta = {
    description = "Render person mail addresses as Kanidm provisioning JSON";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "kanidm-person-mail-provision";
    platforms = lib.platforms.linux;
  };
}
