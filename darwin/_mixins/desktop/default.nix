{ lib, pkgs, ... }:
{
  # Add red borders to windows
  services.jankyborders = {
    enable = true;
    hidpi = true;
    active_color = "0xffe1e3e4";
    inactive_color = "0xff494d64";
  };

  # Configure keybindings
  services.skhd = {
    enable = true;
    skhdConfig =
      let
        fleetingId = "820a2eb5-3d1f-479b-8b73-cb2586646591";
        logToWorkId = "08868c70-a0a7-4c89-9070-ed8580f49707";
        logToPrivateId = "cf68c33c-ada7-4d5b-b5ee-c5e75035c4a6";
        taskToWorkId = "a6a36050-f4c4-49a5-80a2-05471f1d21f8";
        taskToPrivateId = "e810fef2-5240-4c41-bfa4-538534f96ff9";
        obsidianCmd = cmdId: "open 'obsidian://adv-uri?commandid=quickadd%3Achoice%3A${cmdId}'";
        spotifyCmd = cmd: "${pkgs.spotify-player}/bin/spotify_player playback ${cmd}";
        quakeTermCmd = "${pkgs.kitty}/bin/kitten quick-access-terminal";
        newTermCmd = "${lib.getExe pkgs.kitty} --directory ~";
      in
      ''
        # Exact keycodes may be checked @ https://github.com/koekeishiya/skhd/issues/1

        cmd + shift - c : ${obsidianCmd fleetingId}
        cmd + shift - l : ${obsidianCmd logToWorkId}
        cmd + shift - 0x29 : ${obsidianCmd logToPrivateId} # semicolon
        cmd + shift - t : ${obsidianCmd taskToWorkId}
        cmd + shift - y : ${obsidianCmd taskToPrivateId}

        shift - play : ${spotifyCmd "play-pause"}
        shift - next : ${spotifyCmd "next"}
        shift - previous : ${spotifyCmd "previous"}

        cmd - return : ${newTermCmd}
        cmd - 0x32 : ${quakeTermCmd} # backtick
      '';
  };
}
