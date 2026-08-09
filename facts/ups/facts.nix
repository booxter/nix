# Explicit UPS server/client relationships.
{
  servers = [
    "beast"
    "frame"
    "nvws"
    "prx1-lab"
  ];

  clients = {
    builder1 = "prx1-lab";
    builder2 = "prx1-lab";
    builder3 = "prx1-lab";
    cache = "prx1-lab";
    fana = "prx1-lab";
    gw = "prx1-lab";
    home = "prx1-lab";
    mmini = "frame";
    nv = "nvws";
    org = "prx1-lab";
    pki = "prx1-lab";
    prx2-lab = "prx1-lab";
    prx3-lab = "prx1-lab";
    srvarr = "prx1-lab";
  };
}
