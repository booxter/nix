{
  config,
  facts,
  hostSpec,
  lib,
  ...
}:
let
  hostName = hostSpec.name;
  provider = facts.nfs.providers.${hostName} or null;
  hostLinks = facts.nfs.links.${hostName} or { };
  allLinks = lib.concatMapAttrs (
    clientName:
    lib.mapAttrs' (
      linkName: link:
      lib.nameValuePair "${clientName}-${linkName}" (link // { inherit clientName linkName; })
    )
  ) facts.nfs.links;
  providedLinks = lib.filterAttrs (_: link: link.provider == hostName) allLinks;
  providedExports = if provider == null then { } else provider.exports;
  participatingExports =
    providedExports
    // builtins.listToAttrs (
      map (link: {
        name = "${link.provider}-${link.exportName}";
        value = facts.nfs.providers.${link.provider}.exports.${link.exportName};
      }) (builtins.attrValues hostLinks)
    );
  anonymousIdentityNames = lib.unique (
    map (export: export.anonymousIdentity) (
      builtins.attrValues (lib.filterAttrs (_: export: export ? anonymousIdentity) participatingExports)
    )
  );
in
{
  assertions =
    lib.concatMap (
      name:
      let
        expected = facts.accounts.users.${name};
        user = config.users.users.${name} or null;
        group = config.users.groups.${expected.group} or null;
      in
      [
        {
          assertion = user != null && user.uid == expected.uid;
          message = "NFS anonymous identity ${name} must use UID ${toString expected.uid}";
        }
        {
          assertion = group != null && group.gid == facts.accounts.groups.${expected.group}.gid;
          message = "NFS anonymous identity ${name} must use the shared ${expected.group} GID";
        }
      ]
    ) anonymousIdentityNames
    ++ lib.optional (provider != null) {
      assertion = lib.all (
        exportName: builtins.any (link: link.exportName == exportName) (builtins.attrValues providedLinks)
      ) (builtins.attrNames providedExports);
      message = "NFS provider ${hostName} has an export without a client link";
    };
}
