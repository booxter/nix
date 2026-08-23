{
  servers.gw = {
    network = "home";
    cidr = "10.83.0.0/24";
    address = "10.83.0.1";
    listenPort = 51820;
    publicEndpoint = "wg.ihar.dev";
    publicKey = "ftjXEviy3flbMlXVntXs/QDcDUWR9f38nIPAcDTe4Gc=";
    clientPolicy = {
      allowedIPs = [
        "10.83.0.0/24"
        "192.168.0.0/16"
      ];
      dns = [
        "192.168.0.1"
        "home.arpa"
      ];
    };
    dynamicDns = {
      hostname = "ihrachyshka-gw.freeddns.org";
      username = "ihrachyshka";
    };
    qos.uploadLimitMbit = 10;
    externalPeers.unifi-travel-router = {
      address = "10.83.0.20";
      publicKey = "B+s4ysMFr3GrIdXdKP4SxXM3JZ9ziCUVJXkLwEvPX1E=";
    };
  };

  clients.mair = {
    network = "home";
    address = "10.83.0.10";
    publicKey = "j3TbXthVhDk2TVAag6Cr0MRLiCTaOPfBL8UeecG9Sx4=";
    privateKeySecret = "wireguard/gw/privateKey";
  };
}
