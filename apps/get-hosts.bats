#!/usr/bin/env bats

setup() {
  get_hosts="${GET_HOSTS_BIN:?}"
}

@test "returns classified Darwin and NixOS hosts" {
  run "$get_hosts"

  [ "$status" -eq 0 ]
  jq -e '
    (.darwin | type) == "object"
      and (.nixos | type) == "object"
      and .darwin.mair.isWork == false
      and .nixos.beast.isWork == false
      and .nixos.nv.isWork == true
  ' <<< "$output"
}

@test "filters the inventory to requested hosts" {
  run "$get_hosts" mair nvws beast

  [ "$status" -eq 0 ]
  jq -e '
    (.darwin | keys) == ["mair"]
      and (.nixos | keys) == ["beast", "nvws"]
      and .nixos.nvws.isWork == true
  ' <<< "$output"
}
