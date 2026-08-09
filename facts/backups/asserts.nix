{ lib }:
raw:
let
  links = builtins.concatLists (map builtins.attrValues (builtins.attrValues raw.links));
  repositoryPaths = map (link: link.repositoryPath) links;
in
[
  {
    assertion = builtins.length repositoryPaths == builtins.length (lib.unique repositoryPaths);
    message = "backup links must use unique repository paths";
  }
]
