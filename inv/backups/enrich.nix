{ lib }:
facts:
facts
// {
  links = lib.mapAttrs (
    clientName:
    lib.mapAttrs (
      linkName: link:
      let
        provider = facts.providers.${link.provider};
        storageName = link.storageName or clientName;
      in
      link
      // {
        inherit clientName linkName storageName;
        repositoryPath = "${provider.repositoryRoot}/${storageName}";
        ingestUser = "restic-${clientName}";
      }
    )
  ) facts.links;
}
