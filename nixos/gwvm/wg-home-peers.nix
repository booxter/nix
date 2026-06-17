{ hostInventory }:
let
  wgHome = hostInventory.site.wireguard.home;
in
[
  {
    name = "mair";
    publicKey = "j3TbXthVhDk2TVAag6Cr0MRLiCTaOPfBL8UeecG9Sx4=";
    address = wgHome.peers.mair.address;
  }
  {
    name = "unifi-travel-router";
    publicKey = "B+s4ysMFr3GrIdXdKP4SxXM3JZ9ziCUVJXkLwEvPX1E=";
    address = wgHome.peers.unifi-travel-router.address;
  }
]
