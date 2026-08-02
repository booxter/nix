{
  bash,
  bats,
  coreutils,
  git,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "git-send-email-store-password";
  runtimeInputs = [
    coreutils
    git
  ];
  text = builtins.readFile ./git-send-email-store-password.sh;

  derivationArgs = {
    doCheck = true;
  };
  checkPhase = ''
    runHook preCheck
    ${lib.getExe bash} -n "$target"
    ${lib.getExe shellcheck} "$target"
    GIT_SEND_EMAIL_STORE_PASSWORD_BIN=${./git-send-email-store-password.sh} \
      ${lib.getExe bats} --print-output-on-failure ${./git-send-email-store-password.bats}
    runHook postCheck
  '';

  meta = {
    description = "Store the configured Git SMTP password in macOS Keychain";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "git-send-email-store-password";
    platforms = lib.platforms.darwin;
  };
}
