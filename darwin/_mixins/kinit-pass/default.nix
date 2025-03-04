{ pkgs, username, ...} : {
  environment.userLaunchAgents.kinit-pass = {
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>kinit-pass</string>
          <key>ProgramArguments</key>
          <array>
              <string>${pkgs.kinit-pass}/bin/kinit-pass</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
              <key>PASSWORD_STORE_DIR</key>
              <string>/Users/${username}/.local/share/password-store</string>
          </dict>
          <key>StartInterval</key>
          <integer>${toString (60 * 60 * 8)}</integer>
          <key>RunAtLoad</key>
          <true/>
      </dict>
      </plist>
    '';
    target = "kinit-pass.plist";
  };
}
