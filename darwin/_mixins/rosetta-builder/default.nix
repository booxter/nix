{ ... }: {
  nix-rosetta-builder = {
    memory = "16GiB";
    cores = 1;
    onDemand = true;
  };
}
