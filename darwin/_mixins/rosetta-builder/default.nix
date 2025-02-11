{ ... }: {
  nix-rosetta-builder = {
    memory = "24GiB";
    cores = 1;
    onDemand = true;
  };
}
