{ lib, pkgs }:
let
  evaluate =
    settings:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ../../darwin/_mixins/tmpfiles
        {
          options.system.activationScripts = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.text = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                };
              }
            );
            default = { };
          };
          config.system.tmpfiles.settings = settings;
        }
      ];
    }).config.system.activationScripts.users.text;
  directory = {
    mode = "0700";
    user = "__test_user__";
    group = "__test_group__";
  };
  valid = {
    first."/test-root/parent/with spaces".d = directory;
    duplicate."/test-root/parent/with spaces".d = directory;
    first."/test-root/parent".d = directory // {
      mode = "0755";
    };
  };
  rejected = settings: !(builtins.tryEval (builtins.deepSeq (evaluate settings) true)).success;
  invalidSettings = [
    { test."/test-root".f = directory; }
    {
      test."/test-root".d = directory // {
        type = "f";
      };
    }
    {
      test."/test-root".d = directory // {
        age = "1d";
      };
    }
    {
      test."/test-root".d = directory // {
        argument = "content";
      };
    }
    {
      test."/test-root".d = directory // {
        mode = "~0700";
      };
    }
    {
      test."/test-root".d = directory // {
        user = "-";
      };
    }
    { test."/test-root".d = builtins.removeAttrs directory [ "mode" ]; }
    { test."relative".d = directory; }
    { test."/test-root/../elsewhere".d = directory; }
    { test."/test-root/%u".d = directory; }
    { test."/test-root/*".d = directory; }
    {
      first."/test-root".d = directory;
      second."/test-root".d = directory // {
        mode = "0755";
      };
    }
  ];
  activation = pkgs.writeText "tmpfiles-test-activation" (evaluate valid);
  emptyActivation = pkgs.writeText "tmpfiles-test-empty" (evaluate { });
  unsafeActivation = pkgs.writeText "tmpfiles-test-unsafe" (evaluate {
    test."/test-root/unsafe".d = directory;
  });
  storeActivation = pkgs.writeText "tmpfiles-test-store" (evaluate {
    test."/test-root/store-alias/should-not-exist".d = directory;
  });
in
assert builtins.all rejected invalidSettings;
pkgs.runCommand "darwin-tmpfiles" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
  testRoot="$TMPDIR/tmpfiles-test"
  mkdir -p "$testRoot"

  prepare() {
    substitute "$1" "$2" \
      --replace-fail /test-root "$testRoot" \
      --replace-fail __test_user__ "$(id -u)" \
      --replace-fail __test_group__ "$(id -g)"
  }

  prepare ${activation} activate
  bash -e activate
  target="$testRoot/parent/with spaces"
  test "$(stat -c %a "$target")" = 700
  test "$(stat -c %u:%g "$target")" = "$(id -u):$(id -g)"
  test "$(stat -c %a "$testRoot/parent")" = 755

  # Re-activation repairs directory modes, without touching their contents.
    printf 'keep me\n' > "$target/keep"
  chmod 0644 "$target/keep"
  chmod 0755 "$target"
  bash -e activate
  test "$(stat -c %a "$target")" = 700
    test "$(cat "$target/keep")" = "keep me"
    test "$(stat -c %a "$target/keep")" = 644

    # Removing all declarations leaves existing data in place.
    bash -e ${emptyActivation}
    test "$(cat "$target/keep")" = "keep me"

  prepare ${unsafeActivation} unsafe
  mkdir "$testRoot/destination"
  chmod 0755 "$testRoot/destination"
  ln -s "$testRoot/destination" "$testRoot/unsafe"
  if bash -e unsafe; then
    echo "Accepted a symlink directory target" >&2
    exit 1
  fi
  test "$(stat -c %a "$testRoot/destination")" = 755

  rm "$testRoot/unsafe"
  touch "$testRoot/unsafe"
  if bash -e unsafe; then
    echo "Replaced an existing regular file" >&2
    exit 1
  fi
  test -f "$testRoot/unsafe"

  # Ordinary parent aliases work, including macOS-style /var aliases.
  ln -s "$testRoot/parent" "$testRoot/alias"
  substitute unsafe parent-alias \
    --replace-fail "$testRoot/unsafe" "$testRoot/alias/child"
  bash -e parent-alias
  test "$(stat -c %a "$testRoot/parent/child")" = 700

  prepare ${storeActivation} store
  ln -s /nix/store "$testRoot/store-alias"
  if bash -e store; then
    echo "Accepted a directory beneath a store alias" >&2
    exit 1
  fi

  touch "$out"
''
