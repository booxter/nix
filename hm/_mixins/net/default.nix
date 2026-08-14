{
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./wireshark.nix ];

  programs.zsh.initContent = lib.mkAfter ''
    iftop() {
      local primary_iface

      primary_iface="$(
        ip -o route show to default 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
      )"

      if [[ -n "$primary_iface" ]]; then
        sudo ${lib.getExe pkgs.iftop} -b -N -P -o 40s -i "$primary_iface" "$@"
      else
        sudo ${lib.getExe pkgs.iftop} -b -N -P -o 40s "$@"
      fi
    }
  '';
}
