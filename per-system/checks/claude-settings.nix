{ inputs, pkgs }:
let
  json = pkgs.formats.json { };
  configDir = "/claude-settings-test";
  evaluate =
    overrides:
    (inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ../../hm/_mixins/dev/agents/claude/mutable-settings.nix
        {
          home = {
            username = "test";
            homeDirectory = "/home/test";
            stateVersion = "26.05";
          };
          programs.claude-code = {
            enable = true;
            package = null;
            mutableSettings = true;
            inherit configDir;
            settings = {
              env.MANAGED = "nix";
              permissions.allow = [ "Read" ];
            };
            marketplaces.example = pkgs.emptyDirectory;
          };
        }
        overrides
      ];
    }).config;
  activation =
    name: config:
    pkgs.writeShellScript name ''
      set -euo pipefail
      errorEcho() {
        echo "$@" >&2
      }
      ${(config.home.activation.claudeCodeSettings or { data = ""; }).data}
    '';
  config = evaluate { };
  savedSettings = json.generate "claude-saved-settings.json" {
    model = "sonnet";
    env = {
      MANAGED = "changed-in-ui";
      USER = "preserved";
    };
    permissions.allow = [ "Bash" ];
  };
  savedMarketplaces = json.generate "claude-saved-marketplaces.json" {
    example = {
      source = {
        source = "directory";
        path = "/old/path";
      };
      lastUpdated = "2026-10-26T12:00:00Z";
      autoUpdate = true;
    };
    personal.source = "user-owned";
  };
  empty = evaluate (
    { lib, ... }:
    {
      programs.claude-code.settings = lib.mkForce { };
      programs.claude-code.marketplaces = lib.mkForce { };
    }
  );
  disabled = evaluate (
    { lib, ... }:
    {
      programs.claude-code.enable = lib.mkForce false;
    }
  );
in
pkgs.runCommand "claude-settings" { nativeBuildInputs = [ pkgs.jaq ]; } ''
  substitute ${activation "claude-settings-activate" config} "$TMPDIR/activate" \
    --replace-fail '${configDir}' "$TMPDIR/config"

  # First activation creates private writable files. Subsequent activations
  # reapply declared values while preserving preferences saved by Claude.
  bash "$TMPDIR/activate"
  test -w "$TMPDIR/config/settings.json"
  test ! -L "$TMPDIR/config/settings.json"
  test "$(${pkgs.coreutils}/bin/stat -c '%a' "$TMPDIR/config/settings.json")" = 600
  jaq -e '.example.autoUpdate == false' "$TMPDIR/config/plugins/known_marketplaces.json"

  cp ${savedSettings} "$TMPDIR/config/settings.json"
  cp ${savedMarketplaces} "$TMPDIR/config/plugins/known_marketplaces.json"
  bash "$TMPDIR/activate"
  jaq -e '
    .model == "sonnet" and .env.MANAGED == "nix" and
    .env.USER == "preserved" and .permissions.allow == ["Read"]
  ' "$TMPDIR/config/settings.json"
  jaq -e '
    .example.lastUpdated == "2026-10-26T12:00:00Z" and
    .example.autoUpdate == true and
    .example.source.path == "${pkgs.emptyDirectory}" and
    .personal.source == "user-owned"
  ' "$TMPDIR/config/plugins/known_marketplaces.json"

  cp "$TMPDIR/config/settings.json" "$TMPDIR/expected.json"
  bash "$TMPDIR/activate"
  cmp "$TMPDIR/expected.json" "$TMPDIR/config/settings.json"

  # A bad saved file must fail activation without replacing the user's data.
  cp ${pkgs.writeText "broken-settings.json" "{invalid"} "$TMPDIR/config/settings.json"
  if bash "$TMPDIR/activate"; then
    echo "Activation accepted invalid settings" >&2
    exit 1
  fi
  cmp ${pkgs.writeText "broken-settings.json" "{invalid"} "$TMPDIR/config/settings.json"

  # Empty or disabled configurations do not create user settings.
  rm -r "$TMPDIR/config"
  bash ${activation "claude-settings-empty" empty}
  bash ${activation "claude-settings-disabled" disabled}
  test ! -e '${configDir}'

  touch "$out"
''
