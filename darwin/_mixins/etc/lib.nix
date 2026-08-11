{ lib }:
{
  validTarget =
    target:
    target != ""
    && !lib.hasPrefix "/" target
    && !lib.hasInfix "\n" target
    && builtins.all (component: component != "." && component != "..") (lib.splitString "/" target);

  targetsFile =
    pkgs: name: targets:
    pkgs.writeText name (lib.concatMapStrings (target: "${target}\n") targets);

  installEntry =
    entry:
    let
      target = "/etc/${entry.target}";
    in
    ''
      target=${lib.escapeShellArg target}
      temporary="$target.tmp-nix-darwin"
      mkdir -p "$(dirname "$target")"
      rm -f "$temporary"
      install \
        -m ${lib.escapeShellArg entry.mode} \
        -o ${lib.escapeShellArg entry.user} \
        -g ${lib.escapeShellArg entry.group} \
        ${lib.escapeShellArg (toString entry.source)} \
        "$temporary"
      mv -f "$temporary" "$target"
    '';
}
