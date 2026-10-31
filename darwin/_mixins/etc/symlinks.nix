{ inputs, lib, ... }:
{
  disabledModules = [ "system/etc.nix" ];

  imports = [
    (
      { config, pkgs, ... }:
      let
        upstream = import "${inputs.nix-darwin}/modules/system/etc.nix" {
          inherit config lib pkgs;
        };
        # Runtime secrets can be absent when boot activation runs. Keep their
        # configured links, and only remove links whose /etc/static entry is gone.
        replacements = [
          {
            from = "if [[ -e $etcFile ]]; then";
            to = "if [[ -e $etcFile || -L $etcFile ]]; then";
          }
          {
            from = "&& ! -e $etcStaticFile";
            to = "&& ! -e $etcStaticFile && ! -L $etcStaticFile";
          }
        ];
        activation = upstream.config.system.activationScripts.etc.text;
      in
      assert lib.assertMsg (builtins.all (
        replacement: lib.hasInfix replacement.from activation
      ) replacements) "nix-darwin /etc activation changed; review the local dangling-symlink fix";
      lib.recursiveUpdate upstream {
        config.system.activationScripts.etc.text = lib.replaceStrings (map (r: r.from) replacements) (map (
          r: r.to
        ) replacements) activation;
      }
    )
  ];
}
