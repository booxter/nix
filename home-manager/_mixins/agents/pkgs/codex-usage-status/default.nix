{
  bash,
  bats,
  curl,
  jq,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "codex-usage-status";
  runtimeInputs = [
    curl
    jq
  ];
  text = builtins.readFile ./codex-usage-status.sh;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [
      bash
      bats
      jq
      shellcheck
    ];
  };
  checkPhase = ''
    runHook preCheck
    ${lib.getExe bash} -n "$target"
    ${lib.getExe shellcheck} "$target"
    CODEX_USAGE_STATUS_BIN=${./codex-usage-status.sh} \
      ${lib.getExe bats} --print-output-on-failure ${./codex-usage-status.bats}
    runHook postCheck
  '';

  meta = {
    description = "Report Codex rate-limit state";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "codex-usage-status";
  };
}
