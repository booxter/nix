{
  inputs,
  pkgs,
  ...
}:
let
  spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  # The addToQueueTop source was renamed before spicetify-nix caught up.
  priorityQueue = spicePkgs.extensions.addToQueueTop // {
    name = "priority-queue.js";
    src = "${builtins.dirOf spicePkgs.extensions.addToQueueTop.src}/priority-queue";
  };
in
{
  imports = [ inputs.spicetify-nix.homeManagerModules.spicetify ];

  programs.spicetify = {
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
