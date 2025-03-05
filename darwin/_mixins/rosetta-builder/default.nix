{ ... }: {
  nix-rosetta-builder = {
    memory = "24GiB";
    cores = 4;
    onDemand = true;
    permitNonRootSshAccess = true;
  };
}
