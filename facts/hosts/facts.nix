{
  context,
  lib,
}:
let
  inherit (context) frame;

  builderSpecs =
    lib.genAttrs
      (map (idx: "builder${toString idx}") [
        1
        2
        3
      ])
      (_: {
        realm = "home";
        proxmox = {
          cluster = "default";
          guest = {
            memoryGiB = 64;
            balloonGiB = 48;
            diskGiB = 150;
            cores = 24;
          };
        };
      });

  labProxmoxSpecs =
    lib.genAttrs
      (map (index: "prx${toString index}-lab") [
        1
        2
        3
      ])
      (_: {
        hostKind = "proxmox";
        realm = "home";
        proxmox.cluster = "default";
      });
in
{
  darwin = {
    mair = {
      realm = "home";
    };
    mmini = {
      realm = "home";
    };
    JGWXHWDL4X = {
      realm = "work";
    };
  };

  nixos = {
    ${frame} = {
      hostKind = "nixos";
      realm = "home";
      isDesktop = true;
    };
    nvws = {
      hostKind = "proxmox";
      realm = "work";
      proxmox.cluster = "default";
    };
    beast = {
      hostKind = "nixos";
      realm = "home";
    };
    nv = {
      realm = "work";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 64;
          memoryGiB = 128;
        };
      };
    };
    cache = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 16;
          memoryGiB = 16;
          diskGiB = 50; # actual cache is on NFS
        };
      };
    };
    srvarr = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 16;
          memoryGiB = 32;
        };
      };
    };
    fana = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 8;
          memoryGiB = 16;
          diskGiB = 300;
        };
      };
    };
    gw = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 2;
          memoryGiB = 8;
          diskGiB = 64;
        };
      };
    };
    org = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 4;
          memoryGiB = 16;
          diskGiB = 80;
        };
      };
    };
    pki = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 2;
          memoryGiB = 4;
          diskGiB = 50;
        };
      };
    };
    home = {
      realm = "home";
      proxmox = {
        cluster = "default";
        guest = {
          cores = 4;
          memoryGiB = 8;
          diskGiB = 80;
        };
      };
    };
  }
  // labProxmoxSpecs
  // builderSpecs;
}
