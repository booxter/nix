{ pkgs }:
{
  codex-rate-limit-reset-credits = pkgs.writeShellApplication {
    name = "codex-rate-limit-reset-credits";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./codex-rate-limit-reset-credits.sh;
  };
}
