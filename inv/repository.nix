let
  owner = "booxter";
  name = "nix";
in
rec {
  inherit name owner;
  slug = "${owner}/${name}";
  flakeRef = "github:${slug}";
  httpsUrl = "https://github.com/${slug}.git";
  sshUrl = "git@github.com:${slug}.git";
}
