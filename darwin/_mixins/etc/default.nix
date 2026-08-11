{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ./lib.nix { inherit lib; }) installEntry targetsFile;
  manifestPath = "/etc/.nix-darwin-copied";
  enabledEtc = lib.filterAttrs (_: entry: entry.enable) config.environment.etc;
  copiedEtc = lib.filterAttrs (_: entry: entry.mode != "symlink") enabledEtc;
  copiedEntries = builtins.attrValues copiedEtc;
  targets = entries: map (entry: entry.target) entries;
  copiedTargetsFile = targetsFile pkgs "darwin-copied-etc" (targets copiedEntries);
  allTargetsFile = targetsFile pkgs "darwin-managed-etc" (targets (builtins.attrValues enabledEtc));
in
{
  imports = [ ./assertions.nix ];

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
    # nix-darwin rejects regular files where it expects its /etc/static
    # symlinks. Restore those symlinks before its checks, including files
    # copied by the previous generation and files returning to symlink mode.
    system.activationScripts.checks.text = lib.mkBefore ''
      darwinEtcSafeTarget() {
        case "$1" in
          ""|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
          *) return 0 ;;
        esac
      }

      darwinEtcPrepareCopy() {
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
          if darwinEtcSafeTarget "$relativeTarget"; then
            darwinEtcPrepareCopy "$relativeTarget"
          fi
        done < ${manifestPath}
      fi

      while IFS= read -r relativeTarget; do
        if darwinEtcSafeTarget "$relativeTarget"; then
          darwinEtcPrepareCopy "$relativeTarget"
        fi
      done < ${copiedTargetsFile}
    '';

    system.activationScripts.etc.text = lib.mkAfter ''
      if [[ -f ${manifestPath} ]]; then
        while IFS= read -r relativeTarget; do
          if darwinEtcSafeTarget "$relativeTarget" \
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
