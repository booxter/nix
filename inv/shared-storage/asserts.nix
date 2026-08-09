{ lib }:
facts:
let
  resources = builtins.attrValues facts.resources;
  resourcePaths = map (resource: resource.path) resources;
  resourcePathsAreUnique =
    builtins.length resourcePaths == builtins.length (lib.unique resourcePaths);
  directoryPathsAreUnique = lib.all (
    resource:
    let
      paths = map (directory: directory.absolutePath) resource.directories;
    in
    builtins.length paths == builtins.length (lib.unique paths)
  ) resources;
in
[
  {
    assertion = resourcePathsAreUnique;
    message = "shared storage resources must use unique paths";
  }
  {
    assertion = directoryPathsAreUnique;
    message = "shared storage resources must use unique directory paths";
  }
]
