{ vzvm, fetchFromGitHub }:
# Drop once nixpkgs packages 1.1.0: https://github.com/NixOS/nixpkgs/pull/581479
vzvm.overrideAttrs (old: rec {
  version = "1.1.0";
  src = fetchFromGitHub {
    owner = "applicative-systems";
    repo = "vzvm";
    tag = "v${version}";
    hash = "sha256-2DbMZzc3EAc8ZHN7jTX1Yg8mVqq3tA1GLEEYSMX5E/A=";
  };
  passthru = old.passthru // {
    updateScript = null;
  };
})
