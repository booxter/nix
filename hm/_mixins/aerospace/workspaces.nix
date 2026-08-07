{ isNvidia, lib }:

(map toString (lib.range 1 4))
++ [
  "c" # chat
  "e" # email
  "s" # spotify
]
++ (lib.optional isNvidia "t")
