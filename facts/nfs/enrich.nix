{
  accounts,
  lib,
  sharedStorage,
}:
facts:
let
  normalizeExport =
    providerName: exportName: export:
    let
      storageName = export.storage or exportName;
      storage =
        sharedStorage.resources.${storageName}
          or (throw "NFS export ${providerName}.${exportName} references unknown shared storage '${storageName}'");
      sharedGroup = storage.sharedGroup or null;
    in
    export
    // {
      inherit storageName;
      path = storage.path;
    }
    // lib.optionalAttrs (sharedGroup != null) {
      permissions.sharedGroup = {
        name = sharedGroup;
        gid = accounts.groups.${sharedGroup}.gid;
      };
    };
  providers = lib.mapAttrs (
    providerName: provider:
    provider
    // {
      exports = lib.mapAttrs (normalizeExport providerName) provider.exports;
    }
  ) facts.providers;
  normalizeLink =
    clientName: linkName: link:
    let
      provider =
        providers.${link.provider}
          or (throw "NFS link ${clientName}.${linkName} references unknown provider '${link.provider}'");
      exportName = link.export or linkName;
      export =
        provider.exports.${exportName}
          or (throw "NFS link ${clientName}.${linkName} references unknown export '${exportName}' on provider '${link.provider}'");
    in
    link
    // {
      inherit clientName exportName linkName;
      exportPath = export.path;
    };
in
facts
// {
  inherit providers;
  links = lib.mapAttrs (clientName: lib.mapAttrs (normalizeLink clientName)) facts.links;
}
