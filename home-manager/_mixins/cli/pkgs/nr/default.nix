{
  lib,
  nixpkgs-reviewFull,
  writeShellApplication,
}:
writeShellApplication {
  name = "nr";
  runtimeInputs = [ nixpkgs-reviewFull ];
  bashOptions = [ ];
  excludeShellChecks = [
    "SC2046"
    "SC2128"
    "SC2178"
    "SC2206"
  ];
  text = builtins.readFile ./nr;

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nr";
  };
}
