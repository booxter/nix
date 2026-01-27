#!/usr/bin/env bats

setup() {
  source ./scripts/_helpers/update-machines-lib.sh
}

@test "calc_min_disk_kb_from_gib converts GiB to KiB" {
  run calc_min_disk_kb_from_gib 20
  [ "$status" -eq 0 ]
  [ "$output" = "20971520" ]
}

@test "resolve_base_host maps pi5 to dhcp" {
  run resolve_base_host pi5
  [ "$status" -eq 0 ]
  [ "$output" = "dhcp" ]
}

@test "resolve_base_host leaves other hosts unchanged" {
  run resolve_base_host nvws
  [ "$status" -eq 0 ]
  [ "$output" = "nvws" ]
}

@test "hosts_from_work_map returns sorted unique hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run hosts_from_work_map "$work_map"
  [ "$status" -eq 0 ]
  expected=$'mmini\nnvws\npi5'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes only personal hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode personal "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'pi5\nmmini'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes only work hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode work "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'nvws'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes all hosts for both" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode both "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'nvws\npi5\nmmini'
  [ "$output" = "$expected" ]
}

@test "prioritize_hosts orders priority, normal, deferred" {
  run prioritize_hosts prox-cachevm nvws zeta prx2-lab alpha
  [ "$status" -eq 0 ]
  expected=$'nvws\nprx2-lab\nzeta\nalpha\nprox-cachevm'
  [ "$output" = "$expected" ]
}
