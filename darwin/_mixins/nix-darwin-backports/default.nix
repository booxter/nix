{ config, lib, ... }:
let
  cfg = config.users;

  managedUsersWithHomes = lib.filter (
    user: lib.elem user.name cfg.knownUsers && user.name != "root" && user.home != null
  ) (builtins.attrValues cfg.users);

  patchUserHomeCheck =
    user:
    let
      indent = "  ";
      dsclUser = lib.escapeShellArg "/Users/${user.name}";
      configuredHome = lib.escapeShellArg user.home;
      before = ''
        ${indent}homeDirectory=$(dscl . -read ${dsclUser} NFSHomeDirectory)
        ${indent}homeDirectory=''${homeDirectory#NFSHomeDirectory: }
        ${indent}if [[ ${configuredHome} != "$homeDirectory" ]]; then
      '';
      after = ''
        ${indent}homeDirectory=$(dscl . -read ${dsclUser} NFSHomeDirectory)
        ${indent}homeDirectory=''${homeDirectory#NFSHomeDirectory: }
        ${indent}configuredHomeDirectory=$(realpath ${configuredHome})
        ${indent}homeDirectory=$(realpath "$homeDirectory")
        ${indent}if [[ "$configuredHomeDirectory" != "$homeDirectory" ]]; then
      '';
    in
    ''
      substituteInPlace "$out/activate" \
        --replace-fail ${lib.escapeShellArg before} \
                       ${lib.escapeShellArg after}
    '';
in
{
  # TODO(nix-darwin#1803): remove this once
  # https://github.com/nix-darwin/nix-darwin/pull/1803 lands in the pinned
  # nix-darwin input.
  # macOS stores /var homes as /private/var in Directory Services; compare the
  # real paths so activation does not reject equivalent home directories.
  system.systemBuilderCommands = lib.mkIf (managedUsersWithHomes != [ ]) (
    lib.mkAfter ''
      ${lib.concatMapStringsSep "\n" patchUserHomeCheck managedUsersWithHomes}

      shellcheck --exclude=SC2016,SC1112 "$out/activate"
    ''
  );
}
