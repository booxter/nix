{ ... }: {
  nix-rosetta-builder = {
    memory = "24GiB";
    cores = 8;
    onDemand = true;
    permitNonRootSshAccess = true;
  };
}
