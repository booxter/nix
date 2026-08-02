{
  bash,
  bats,
  codexUsageStatus,
  curl,
  jq,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "codex-warmer";
  runtimeInputs = [
    codexUsageStatus
    curl
    jq
  ];
  text = builtins.readFile ./codex-warmer.sh;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [ jq ];
  };
  checkPhase = ''
    runHook preCheck
    ${lib.getExe bash} -n "$target"
    ${lib.getExe shellcheck} "$target"
    CODEX_WARMER_BIN=${./codex-warmer.sh} \
      ${lib.getExe bats} --print-output-on-failure ${./codex-warmer.bats}
    runHook postCheck
  '';

  meta = {
    description = "Start an inactive Codex five-hour usage window";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "codex-warmer";
  };
}
