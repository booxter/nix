{ lib, pkgs, ... }: lib.hm.dag.entryAfter ["writeBoundary"] ''
  open -a ${pkgs.cb_thunderlink-native}/Applications/Thunderlink.app
''
