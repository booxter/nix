{
  inputs,
  lib,
  pkgs,
}:
let
  evaluated = lib.evalModules {
    specialArgs = {
      inherit inputs pkgs;
      modulesPath = "${inputs.nix-darwin}/modules";
    };
    modules = [
      "${inputs.nix-darwin}/modules/system/etc.nix"
      ../../darwin/_mixins/etc/symlinks.nix
      {
        options.system = {
          build.etc = lib.mkOption { type = lib.types.package; };
          activationScripts = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.text = lib.mkOption { type = lib.types.lines; };
              }
            );
          };
        };
      }
    ];
  };
  # Redirect live /etc paths into the fixture, preserving the generation path.
  activation = pkgs.writeText "darwin-etc-test-activation" (
    lib.replaceStrings [ "$systemConfig/etc" "/etc" ] [ "$systemConfig/etc" "$testRoot/etc" ]
      evaluated.config.system.activationScripts.etc.text
  );
in
pkgs.runCommand "darwin-etc"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      findutils
    ];
  }
  ''
    export testRoot="$TMPDIR/activation-test"
    export systemConfig="$testRoot/generation"
    mkdir -p "$systemConfig/etc/nut" "$testRoot/etc/nut" "$testRoot/secrets"
    ln -s "$testRoot/secrets/upsmon.conf" "$systemConfig/etc/nut/upsmon.conf"

    activate() {
      bash -e ${activation}
    }

    assertConfiguredLink() {
      test -L "$testRoot/etc/nut/upsmon.conf"
      test "$(readlink "$testRoot/etc/nut/upsmon.conf")" = "$testRoot/etc/static/nut/upsmon.conf"
    }

    # First activation must retain a configured link even before secrets exist.
    activate
    assertConfiguredLink
    test ! -e "$testRoot/etc/nut/upsmon.conf"

    # A reboot can encounter that same dangling link before secrets are installed.
    activate
    assertConfiguredLink

    printf 'test secret\n' > "$testRoot/secrets/upsmon.conf"
    activate
    assertConfiguredLink
    test "$(cat "$testRoot/etc/nut/upsmon.conf")" = "test secret"

    # Removing the secret again must not turn a configured link into a stale one.
    rm "$testRoot/secrets/upsmon.conf"
    activate
    assertConfiguredLink

    # Only removing the configuration entry makes the link stale.
    rm "$systemConfig/etc/nut/upsmon.conf"
    activate
    test ! -L "$testRoot/etc/nut/upsmon.conf"

    touch "$out"
  ''
