{
  lib,
  pkgs,
  username,
  ...
}:
let
  profileName = "Nix";
  profileKey = "Window Settings.${profileName}";
  terminalProfile = ./Nix.terminal;
  installTerminalProfile = pkgs.writeShellScript "install-terminal-profile" ''
    set -eu

    tmp_dir=$(/usr/bin/mktemp -d /tmp/nix-terminal-profile.XXXXXX)
    trap '/bin/rm -rf "$tmp_dir"' EXIT

    preferences="$tmp_dir/preferences.plist"
    current_profile="$tmp_dir/current-profile.plist"
    desired_profile="$tmp_dir/desired-profile.plist"

    /usr/bin/plutil -convert xml1 -o "$desired_profile" ${terminalProfile}

    if ! /usr/bin/defaults export com.apple.Terminal "$preferences"; then
      /usr/bin/plutil -create xml1 "$preferences"
    fi

    if /usr/bin/plutil -extract ${lib.escapeShellArg profileKey} xml1 \
      -o "$current_profile" "$preferences" 2>/dev/null \
      && /usr/bin/cmp -s "$current_profile" "$desired_profile"; then
      exit 0
    fi

    profile_xml="$(/usr/bin/plutil -convert xml1 -o - ${terminalProfile})"
    if ! /usr/bin/plutil -type 'Window Settings' "$preferences" >/dev/null 2>&1; then
      /usr/bin/plutil -insert 'Window Settings' -dictionary "$preferences"
    fi

    if /usr/bin/plutil -type ${lib.escapeShellArg profileKey} "$preferences" >/dev/null 2>&1; then
      /usr/bin/plutil -replace ${lib.escapeShellArg profileKey} -xml "$profile_xml" "$preferences"
    else
      /usr/bin/plutil -insert ${lib.escapeShellArg profileKey} -xml "$profile_xml" "$preferences"
    fi

    /usr/bin/defaults import com.apple.Terminal "$preferences"
  '';
in
{
  system.defaults.CustomUserPreferences."com.apple.Terminal" = {
    SecureKeyboardEntry = false; # otherwise focused Terminal disables Aerospace bindings
    "Default Window Settings" = profileName;
    "Startup Window Settings" = profileName;
  };

  system.activationScripts.userDefaults.text = lib.mkAfter ''
    echo >&2 "installing Terminal profile..."
    user=${lib.escapeShellArg username}
    /bin/launchctl asuser "$(/usr/bin/id -u -- "$user")" \
      /usr/bin/sudo --user="$user" -- ${installTerminalProfile}
  '';
}
