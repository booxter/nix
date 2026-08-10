{ lib, ... }:
let
  passwordSecret = name: "jellyfin/users/${lib.toLower name}/password";
  definitions = [
    {
      name = "Ihar";
      isAdmin = true;
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "jellyfin";
      isAdmin = false;
      isAdult = false;
    }
    {
      name = "Kasia";
      isAdult = true;
      allowWrite = true;
    }
    {
      name = "Vatslau";
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
      allLibraries = false;
    }
    {
      name = "ZD";
      isAdmin = false;
      isKid = false;
      isAdult = true;
      isGuest = true;
      allLibraries = true;
    }
    {
      name = "ZS";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      allLibraries = false;
      extraLibraries = [ "Attic" ];
    }
    {
      name = "Olga";
      isAdmin = false;
      isKid = false;
      isAdult = false;
      isGuest = true;
      allLibraries = false;
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
      allLibraries ? false,
      extraLibraries ? [ ],
    }:
    {
      inherit name;
      passwordSecret = passwordSecret name;
      policy = {
        isAdministrator = isAdmin;
        enableAllFolders = allLibraries;
        enableCollectionManagement = allowWrite || isAdmin;
        enableContentDownloading = true;
        loginAttemptsBeforeLockout = 3;
        # 10 Mbps (Jellyfin policy expects bits/sec). Spectrum upload is
        # maxed at 35 Mbps, leaving room for several streams and backups.
        remoteClientBitrateLimit = 10 * 1000 * 1000;
      }
      // lib.optionalAttrs isGuest {
        maxActiveSessions = 4;
      }
      // lib.optionalAttrs (!allLibraries) {
        enabledLibraries = [
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
        ++ extraLibraries;
      };
      displayMissingEpisodes = true;
      subtitleLanguagePreference = "eng";
    };
in
{
  host.jellyfin.declarativeConfig.users = map getUser definitions;
}
