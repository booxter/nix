{ pkgs, ... }:
{
  package = pkgs.get-ff-cookie;
  description = "Export Firefox cookies as Netscape cookies.txt on stdout.";
}
