{ hostInventory, lib, ... }:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  hostKeyPath = name: ../../../public-keys/hosts + "/${name}.pub";
  mkKnownHost = name: hostNames: {
    inherit name;
    value = {
      hostNames = lib.unique hostNames;
      publicKey = readPublicKey (hostKeyPath name);
    };
  };
  nixosKnownHosts = builtins.listToAttrs (
    map (
      spec:
      mkKnownHost spec.name (
        hostInventory.toNixosHostCertificateDnsNames spec
        ++ map hostInventory.toLocalDnsName (hostInventory.toNixosMigrationDnsNames spec)
      )
    ) hostInventory.nixosHostSpecs
  );
  darwinKnownHosts = lib.mapAttrs' (
    name: spec:
    let
      hostname = spec.hostname or name;
      dnsName = spec.dnsName or hostname;
      names = [
        name
        hostname
        dnsName
      ];
    in
    mkKnownHost name (
      names
      ++ map lib.toLower names
      ++ map hostInventory.toLocalDnsName names
      ++ map (host: hostInventory.toLocalDnsName (lib.toLower host)) names
    )
  ) hostInventory.darwinHosts;
  initrdKnownHosts.frame-initrd = {
    hostNames = [ "frame-initrd" ];
    publicKey = readPublicKey ../../../public-keys/hosts/frame-initrd.pub;
  };
in
{
  programs.ssh.knownHosts = nixosKnownHosts // darwinKnownHosts // initrdKnownHosts;
}
