{
  config,
  lib,
  ...
}:
let
  jellyfin = config.services.jellyfin;
  passwordSecret = name: "jellyfin/users/${lib.toLower name}/password";
  secretFile = {
    owner = jellyfin.user;
    inherit (jellyfin) group;
    mode = "0400";
  };
  users = [
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
  renderUser =
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
      passwordFile = config.sops.secrets.${passwordSecret name}.path;
      policy = {
        isAdministrator = isAdmin;
        enableAllFolders = allLibraries;
        enableCollectionManagement = allowWrite || isAdmin;
        enableContentDownloading = true;
        loginAttemptsBeforeLockout = 3;
        # 10 Mbps (Jellyfin policy expects bits/sec). Spectrum upload is maxed
        # at 35 Mbps, leaving room for a few streams and background traffic.
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
  sops.secrets = lib.genAttrs (map (user: passwordSecret user.name) users) (_: secretFile);
  services.jellarr.config.users = map renderUser users;
}
