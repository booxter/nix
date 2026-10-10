{ lib, pkgs }:
{
  # Keep this limited to literal directory paths, not tmpfiles specifiers or globs.
  validPath =
    path:
    lib.hasPrefix "/" path
    && path != "/"
    && builtins.all (part: part != "" && part != "." && part != "..") (
      lib.tail (lib.splitString "/" path)
    )
    && builtins.all (character: !lib.hasInfix character path) [
      "%"
      "*"
      "?"
      "["
      "]"
      "\n"
      "\r"
    ];

  directoryFunction = ''
    darwinTmpfilesDirectory() {
      local target="$1" mode="$2" owner="$3" group="$4"
      local resolved

      if [[ -L "$target" ]]; then
        echo "tmpfiles: directory target is a symlink: $target" >&2
        return 1
      fi

      # Resolve parent aliases such as /var, but never operate inside the store.
      resolved="$(${pkgs.coreutils}/bin/realpath -m -- "$target")" || return 1
      case "$resolved" in
        /nix/store|/nix/store/*)
          echo "tmpfiles: refusing directory in the Nix store: $target" >&2
          return 1
          ;;
      esac

      ${pkgs.coreutils}/bin/install -d -m "$mode" -o "$owner" -g "$group" -- "$target"
    }
  '';

  directoryCommand = path: rule: ''
    darwinTmpfilesDirectory ${
      lib.escapeShellArgs [
        path
        rule.mode
        rule.user
        rule.group
      ]
    }
  '';
}
