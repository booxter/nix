{ lib, isWork }:

(map toString (lib.range 1 6))
++ [
  "c" # chat
  "e" # email
  "s" # spotify
]
++ (lib.optional isWork "t")
