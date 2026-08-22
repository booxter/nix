{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.spotify;
  spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  # The addToQueueTop source was renamed before spicetify-nix caught up.
  priorityQueue = spicePkgs.extensions.addToQueueTop // {
    name = "priority-queue.js";
    src = "${dirOf spicePkgs.extensions.addToQueueTop.src}/priority-queue";
  };
in
{
  imports = [ inputs.spicetify-nix.homeManagerModules.spicetify ];

  home.activation.blockSpotifyUpdates =
    lib.mkIf (cfg.enable && cfg.spicetify.enable && pkgs.stdenv.hostPlatform.isDarwin)
      (
        lib.hm.dag.entryBefore [ "copyApps" ] ''
          spotify_update_dir=${lib.escapeShellArg "${config.home.homeDirectory}/Library/Application Support/Spotify/PersistentCache/Update"}

          run /bin/mkdir -p "$spotify_update_dir"
          run /usr/bin/chflags uchg "$spotify_update_dir"
        ''
      );

  programs.spicetify = lib.mkIf (cfg.enable && cfg.spicetify.enable) {
    enable = true;
    enabledExtensions = with spicePkgs.extensions; [
      aiBandBlocker
      shuffle
      keyboardShortcut
      priorityQueue
      showQueueDuration
      volumePercentage
      fullAlbumDate
      listPlaylistsWithSong
      sleepTimer
      beautifulLyrics
    ];

    enabledCustomApps = with spicePkgs.apps; [
      newReleases
      historyInSidebar
    ];
  };
}
