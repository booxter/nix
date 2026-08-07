{
  config,
  lib,
  pkgs,
  ...
}:
let
  manifestPath = "/etc/.nix-darwin-copied";
  enabledEtc = lib.filterAttrs (_: entry: entry.enable) config.environment.etc;
  copiedEtc = lib.filterAttrs (_: entry: entry.mode != "symlink") enabledEtc;
  copiedEntries = builtins.attrValues copiedEtc;
  targets = map (entry: entry.target);
  copiedTargets = targets copiedEntries;
  allTargets = targets (builtins.attrValues enabledEtc);
  targetsFile = name: values: pkgs.writeText name (lib.concatMapStrings (value: "${value}\n") values);
  copiedTargetsFile = targetsFile "darwin-copied-etc" copiedTargets;
  allTargetsFile = targetsFile "darwin-managed-etc" allTargets;
  validTarget =
    target:
    target != ""
    && !lib.hasPrefix "/" target
    && !lib.hasInfix "\n" target
    && builtins.all (component: component != "." && component != "..") (lib.splitString "/" target);
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
in
{
  options.environment.etc = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = lib.types.strMatching "(symlink|[0-7][0-7][0-7][0-7])";
            default = "symlink";
            description = "File mode, or symlink to retain nix-darwin's default behavior.";
          };

          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Owner of a copied file.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "wheel";
            description = "Group of a copied file.";
          };
        };
      }
    );
  };

  config = {
    assertions = map (entry: {
      assertion = validTarget entry.target;
      message = "Copied environment.etc target '${entry.target}' must be a safe path relative to /etc.";
    }) copiedEntries;

    # nix-darwin rejects regular files where it expects its /etc/static
    # symlinks. Restore the symlinks before its checks, including files copied
    # by the previous generation and files migrating to copy mode now.
    system.activationScripts.checks.text = lib.mkBefore ''
      isSafeEtcTarget() {
        case "$1" in
          ""|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
          *) return 0 ;;
        esac
      }

      prepareEtcCopy() {
        local relativeTarget="$1"
        local etcFile="/etc/$relativeTarget"
        local staticFile="/etc/static/$relativeTarget"

        if [[ -e "$etcFile" || -L "$etcFile" ]]; then
          if [[ -e "$staticFile" || -L "$staticFile" ]]; then
            local temporary="$etcFile.tmp-nix-darwin"
            rm -f "$temporary"
            ln -s "$staticFile" "$temporary"
            mv -f "$temporary" "$etcFile"
          else
            rm -f "$etcFile"
          fi
        fi
      }

      if [[ -f ${manifestPath} ]]; then
        while IFS= read -r relativeTarget; do
          if isSafeEtcTarget "$relativeTarget"; then
            prepareEtcCopy "$relativeTarget"
          fi
        done < ${manifestPath}
      fi

      while IFS= read -r relativeTarget; do
        if isSafeEtcTarget "$relativeTarget"; then
          prepareEtcCopy "$relativeTarget"
        fi
      done < ${copiedTargetsFile}
    '';

    system.activationScripts.etc.text = lib.mkAfter ''
      if [[ -f ${manifestPath} ]]; then
        while IFS= read -r relativeTarget; do
          if isSafeEtcTarget "$relativeTarget" \
            && ! /usr/bin/grep -Fqx "$relativeTarget" ${allTargetsFile}; then
            rm -f "/etc/$relativeTarget"
          fi
        done < ${manifestPath}
      fi

      ${lib.concatMapStringsSep "\n" installEntry copiedEntries}

      install -m 0444 -o root -g wheel ${copiedTargetsFile} ${manifestPath}.tmp
      mv -f ${manifestPath}.tmp ${manifestPath}
    '';
  };
}
