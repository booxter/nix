{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  passwordSecret = name: "jellyfin/users/${lib.toLower name}/password";
  definitions = [
    {
      name = "Ihar";
      audioLanguagePreference = "eng";
      subtitleMode = "Always";
      isAdmin = true;
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "jellyfin";
      subtitleMode = "Always";
      isAdmin = false;
      isAdult = false;
    }
    {
      name = "Kasia";
      subtitleMode = "Always";
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "Vatslau";
      subtitleMode = "Always";
      isKid = true;
    }
    {
      name = "Guest";
      isAdmin = false;
      isAdult = false;
      allowWrite = false;
    }
    {
      name = "DZ";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
    }
    {
      name = "ZD";
      isAdmin = false;
      isKid = false;
      isAdult = true;
      isGuest = true;
    }
    {
      name = "ZS";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      extraLibraries = [ "Attic" ];
    }
    {
      name = "Olga";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
    }
    {
      name = "Alex";
      localized = true;
      isGuest = true;
      extraLibraries = [ "Attic" ];
      excludedLibraries = [
        "Anime"
        "Stand-up"
      ];
      orderedLibraries = [
        "Movies"
        "Attic"
        "Family"
        "Docu"
        "Music"
        "Shows"
      ];
      audioLanguagePreference = "rus";
      subtitleLanguagePreference = "rus";
      subtitleMode = "Smart";
      allowedTags = [
        "language_Russian"
        "non_media"
      ];
    }
  ];
  getUser =
    {
      name,
      isAdmin ? false,
      allowWrite ? false,
      isKid ? false,
      isAdult ? false,
      isGuest ? false,
      localized ? false,
      extraLibraries ? [ ],
      excludedLibraries ? [ ],
      orderedLibraries ? null,
      audioLanguagePreference ? null,
      subtitleLanguagePreference ? "eng",
      subtitleMode ? null,
      allowedTags ? null,
    }:
    let
      libraryName = name: if localized then model.localizedNames.${name} or name else name;
    in
    {
      inherit name subtitleLanguagePreference;
      passwordSecret = passwordSecret name;
      policy = {
        isAdministrator = isAdmin;
        enableAllFolders = false;
        enableCollectionManagement = allowWrite || isAdmin;
        enableContentDownloading = true;
        loginAttemptsBeforeLockout = 3;
        # 10 Mbps (Jellyfin policy expects bits/sec). Spectrum upload is
        # maxed at 35 Mbps, leaving room for several streams and backups.
        remoteClientBitrateLimit = 10 * 1000 * 1000;
      }
      // lib.optionalAttrs (allowedTags != null) {
        inherit allowedTags;
      }
      // lib.optionalAttrs isGuest {
        maxActiveSessions = 4;
      }
      // {
        # Libraries without a localized mirror, such as Music, stay shared.
        enabledLibraries = map libraryName (
          lib.subtractLists excludedLibraries (
            [
              "Family"
            ]
            ++ lib.optionals (!isKid) [
              "Movies"
              "Shows"
              "Anime"
              "Docu"
              "Stand-up"
              "Music"
            ]
            ++ lib.optionals isAdult [
              "Attic"
              "Fruit"
              "Fruitsies"
            ]
            ++ extraLibraries
          )
        );
      };
      displayMissingEpisodes = true;
    }
    // lib.optionalAttrs (orderedLibraries != null) {
      orderedLibraries = map libraryName orderedLibraries;
    }
    // lib.optionalAttrs (subtitleMode != null) {
      inherit subtitleMode;
    }
    // lib.optionalAttrs (audioLanguagePreference != null) {
      inherit audioLanguagePreference;
      playDefaultAudioTrack = false;
    };
in
{
  host.jellyfinDeclarativeConfig.users = map getUser definitions;
}
