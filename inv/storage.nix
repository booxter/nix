let
  beast = "beast";
  diskBayRows = 5;
  sataHdd =
    bay: serial: model:
    let
      index = bay - 1;
      col = builtins.div index diskBayRows + 1;
      row = index - (builtins.div index diskBayRows * diskBayRows) + 1;
    in
    {
      bay = toString bay;
      col = toString col;
      inherit model;
      media = "hdd";
      row = toString row;
      inherit serial;
      transport = "sata";
    };
  diskNm000H = bay: serial: sataHdd bay serial "ST24000NM000H-3KS103";
  diskNm000C = bay: serial: sataHdd bay serial "ST24000NM000C-3WD103";
  nvmeSystemDisk = layout: {
    device = "/dev/nvme0n1";
    inherit layout;
    transport = "nvme";
  };
  dataVolume = {
    device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
    fsType = "btrfs";
    mounts.data = {
      mountPoint = "/volume2";
      requiredForBoot = false;
    };
  };
  export = path: fsid: clientHosts: {
    server = beast;
    path = "${dataVolume.mounts.data.mountPoint}/${path}";
    backingMount = dataVolume.mounts.data.mountPoint;
    inherit clientHosts fsid;
    clientServices = [ ];
  };
  mediaLayout = {
    library = rec {
      root = "library";
      audiobooks = "${root}/audiobooks";
      books = "${root}/books";
      flows = "${root}/flows";
      collections = {
        anime = "${root}/anime";
        attic = "${root}/attic";
        docu = "${root}/docu";
        family = "${root}/family";
        fruit = "${root}/xxx";
        fruitsies = "${root}/fruitsies";
        movies = "${root}/movies";
        music = "${root}/music";
        shows = "${root}/shows";
        standup = "${root}/standup";
      };
    };
    pinepods = rec {
      root = "podcasts";
      downloads = "${root}/pinepods";
    };
    romm = rec {
      root = "romm";
      assets = "${root}/assets";
      cache = "${root}/cache";
      config = "${root}/config";
      resources = "${root}/resources";
      sync = "${root}/sync";
      library = "${root}/library";
      roms = "${library}/roms";
      pcRoms = "${roms}/pc";
      bios = "${library}/bios";
    };
    sabnzbd = rec {
      root = "usenet";
      incomplete = "${root}/.incomplete";
      watch = "${root}/watch";
      complete = "${root}/manual";
      categories = {
        lidarr = "${root}/lidarr";
        radarr = "${root}/radarr";
        shelfmark = "${root}/shelfmark";
        sonarr = "${root}/sonarr";
      };
    };
    slskd = rec {
      root = "slskd";
      incomplete = "${root}/incomplete";
      complete = "${root}/complete";
    };
    transmission = rec {
      root = "torrents";
      incomplete = "${root}/.incomplete";
      watch = "${root}/.watch";
      categories = {
        lidarr = "${root}/lidarr";
        manual = "${root}/manual";
        radarr = "${root}/radarr";
        shelfmark = "${root}/shelfmark";
        sonarr = "${root}/sonarr";
      };
    };
  };
in
{
  hosts.${beast} = {
    systemDisk = nvmeSystemDisk "ext4";
    volumes.data = dataVolume;
    diskBays = {
      hbaBackend = "storcli";
      rows = diskBayRows;
      disks = [
        (diskNm000H 1 "ZYD01W48")
        (diskNm000H 3 "ZYD0CASB")
        (diskNm000H 5 "ZYD05Z4J")
        (diskNm000H 6 "ZYD041CP")
        (diskNm000C 7 "ZXA0RKFF")
        (diskNm000C 9 "ZXA0B5K4")
        (diskNm000C 10 "ZXA0FFNN")
        (diskNm000H 11 "ZYD01W92")
        (diskNm000C 12 "ZXA0GW38")
        (diskNm000H 13 "ZYD02EQQ")
        (diskNm000C 15 "ZXA0ENE4")
      ];
      raidSets.data = {
        implementation = "md";
        level = 6;
        memberBays = [
          "1"
          "3"
          "5"
          "6"
          "7"
          "9"
          "10"
          "11"
          "12"
          "13"
          "15"
        ];
        volume = "data";
      };
    };
  };
  hosts.frame = {
    systemDisk = nvmeSystemDisk "luks-btrfs";
    volumes.system = {
      device = "/dev/mapper/crypted";
      fsType = "btrfs";
      mounts = {
        root.mountPoint = "/";
        home.mountPoint = "/home";
        nix = {
          mountPoint = "/nix";
          snapshots = false;
        };
      };
    };
  };
  hosts.nvws.systemDisk = nvmeSystemDisk "ext4";
  hosts."prx1-lab".systemDisk = nvmeSystemDisk "ext4";
  hosts."prx2-lab".systemDisk = nvmeSystemDisk "ext4";
  hosts."prx3-lab".systemDisk = nvmeSystemDisk "ext4";

  nfs.exports = {
    media = (export "Media" 10 [ "srvarr" ]) // {
      clientServices = [
        "aurral"
        "audiobookshelf"
        "bazarr"
        "jellyfin"
        "lidarr"
        "pinepods"
        "radarr"
        "romm"
        "sabnzbd"
        "shelfmark"
        "slskd"
        "sonarr"
        "watchstate"
      ];
      layout = mediaLayout;
      sharedGroup = {
        name = "media";
        gid = 169;
      };
    };
    nixCache = export "nix-cache" 11 [ "cache" ];
    paperless = (export "paperless" 12 [ "org" ]) // {
      # Preserve root_squash while presenting root-run client backup jobs as
      # the Paperless service identity.
      anonymousIdentity = "paperless";
      layout = {
        consume = "consume";
        export = "export";
        media = "media";
      };
    };
  };
}
