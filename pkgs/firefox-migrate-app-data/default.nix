{
  coreutils,
  findutils,
  lib,
  runCommandLocal,
  writeShellApplication,
  sourceRelativePath ? "Library/Application Support/Firefox",
  destinationRelativePath ? "Library/Application Support/org.nixos.firefox",
}:
let
  package = writeShellApplication {
    name = "firefox-migrate-app-data";
    runtimeInputs = [
      coreutils
      findutils
    ];
    text = ''
      source_relative_path=${lib.escapeShellArg sourceRelativePath}
      destination_relative_path=${lib.escapeShellArg destinationRelativePath}
    ''
    + builtins.readFile ./firefox-migrate-app-data.sh;

    meta = {
      description = "Migrate Firefox app data out of Mozilla's protected macOS directory";
      license = lib.licenses.mit;
      mainProgram = "firefox-migrate-app-data";
      platforms = lib.platforms.darwin;
    };
  };

  test =
    runCommandLocal "firefox-migrate-app-data-test"
      {
        nativeBuildInputs = [ package ];
      }
      ''
        export HOME="$TMPDIR/home"
        export FIREFOX_MIGRATE_SKIP_RUNNING_CHECK=1

        source_dir="$HOME/"${lib.escapeShellArg sourceRelativePath}
        destination_dir="$HOME/"${lib.escapeShellArg destinationRelativePath}
        destination_parent=''${destination_dir%/*}

        mkdir -p "$source_dir/Profiles/default"
        printf '[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/default\n' > "$source_dir/profiles.ini"
        printf 'original\n' > "$source_dir/Profiles/default/state"
        touch "$source_dir/Profiles/default/.parentlock"

        firefox-migrate-app-data --dry-run
        test ! -e "$destination_dir"

        firefox-migrate-app-data
        test -e "$source_dir/profiles.ini"
        test -e "$destination_dir/profiles.ini"
        test ! -e "$destination_dir/Profiles/default/.parentlock"
        grep -Fx original "$destination_dir/Profiles/default/state"

        if firefox-migrate-app-data; then
          echo "migration unexpectedly replaced an existing destination" >&2
          exit 1
        fi

        printf 'replacement\n' > "$source_dir/Profiles/default/state"
        printf 'backup marker\n' > "$destination_dir/backup-marker"
        firefox-migrate-app-data --replace-existing
        grep -Fx replacement "$destination_dir/Profiles/default/state"

        backup_dir=$(find "$destination_parent" -maxdepth 1 -type d \
          -name ${lib.escapeShellArg "${baseNameOf destinationRelativePath}.pre-migration.*"} -print -quit)
        test -n "$backup_dir"
        grep -Fx 'backup marker' "$backup_dir/backup-marker"

        touch "$out"
      '';
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests.migration = test;
  };
})
