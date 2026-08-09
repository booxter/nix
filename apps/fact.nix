{
  facts,
  pkgs,
}:
let
  names = builtins.attrNames facts;
  cases = pkgs.lib.concatMapStringsSep "\n" (name: ''
    ${pkgs.lib.escapeShellArg name})
      printf '%s\n' ${pkgs.lib.escapeShellArg (builtins.toJSON facts.${name})}
      ;;
  '') names;
  listedNames = pkgs.lib.concatMapStringsSep " " pkgs.lib.escapeShellArg names;
in
pkgs.writeShellApplication {
  name = "fact";
  text = ''
    if [[ $# -ne 1 ]]; then
      echo "usage: fact --list | fact <name>" >&2
      exit 2
    fi

    case "$1" in
      --list)
        printf '%s\n' ${listedNames}
        ;;
      ${cases}
      *)
        printf 'unknown fact library: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  '';
  meta.description = "List fact libraries or print one as JSON.";
}
