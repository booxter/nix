{
  clusters = {
    lab = {
      controller = "prx1-lab";
      nodes = [
        "prx1-lab"
        "prx2-lab"
        "prx3-lab"
      ];
    };
    nvws = {
      controller = "nvws";
      nodes = [ "nvws" ];
    };
  };

  guests = {
    builder1 = "lab";
    builder2 = "lab";
    builder3 = "lab";
    cache = "lab";
    fana = "lab";
    gw = "lab";
    home = "lab";
    nv = "nvws";
    org = "lab";
    pki = "lab";
    srvarr = "lab";
  };

  nodes = {
    nvws = "nvws";
    prx1-lab = "lab";
    prx2-lab = "lab";
    prx3-lab = "lab";
  };
}
