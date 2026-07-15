{
  lib,
  pkgs,
  username,
  ...
}:
let
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

    if /usr/bin/plutil -extract 'Window Settings.Nix' xml1 \
      -o "$current_profile" "$preferences" 2>/dev/null \
      && /usr/bin/cmp -s "$current_profile" "$desired_profile"; then
      exit 0
    fi

    profile_xml="$(/usr/bin/plutil -convert xml1 -o - ${terminalProfile})"
    if ! /usr/bin/plutil -type 'Window Settings' "$preferences" >/dev/null 2>&1; then
      /usr/bin/plutil -insert 'Window Settings' -dictionary "$preferences"
    fi

    if /usr/bin/plutil -type 'Window Settings.Nix' "$preferences" >/dev/null 2>&1; then
      /usr/bin/plutil -replace 'Window Settings.Nix' -xml "$profile_xml" "$preferences"
    else
      /usr/bin/plutil -insert 'Window Settings.Nix' -xml "$profile_xml" "$preferences"
    fi

    /usr/bin/defaults import com.apple.Terminal "$preferences"
  '';
in
{
  system.defaults.CustomUserPreferences."com.apple.Terminal" = {
    # skhd requires Secure Keyboard Entry to be disabled.
    "SecureKeyboardEntry" = false;
    "Default Window Settings" = "Nix";
    "Startup Window Settings" = "Nix";
  };

  system.activationScripts.userDefaults.text = lib.mkAfter ''
    echo >&2 "installing Terminal profile..."
    user=${lib.escapeShellArg username}
    /bin/launchctl asuser "$(/usr/bin/id -u -- "$user")" \
      /usr/bin/sudo --user="$user" -- ${installTerminalProfile}
  '';
}
