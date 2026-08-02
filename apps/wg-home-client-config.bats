#!/usr/bin/env bats

setup() {
  wg_home_client_config="${WG_HOME_CLIENT_CONFIG_BIN:?}"
  private_key_file="$BATS_TEST_TMPDIR/client.key"
  printf '%s\n' 'test-private-key' > "$private_key_file"
}

@test "help lists inventory-backed peers" {
  run "$wg_home_client_config" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"--peer mair"* ]]
  [[ "$output" == *"Inventory-backed peers: mair"* ]]
}

@test "renders an inventory peer configuration" {
  run "$wg_home_client_config" \
    --peer mair \
    --private-key-file "$private_key_file" \
    --server-public-key test-server-pubkey

  [ "$status" -eq 0 ]
  [[ "$output" == *"Address = 10.83.0.10/32"* ]]
  [[ "$output" == *"DNS = 192.168.0.1, home.arpa"* ]]
  [[ "$output" == *"Endpoint = ${WG_HOME_TEST_ENDPOINT:?}"* ]]
  [[ "$output" == *"AllowedIPs = 10.83.0.0/24, 192.168.0.0/16"* ]]
}

@test "renders an explicit peer address" {
  run "$wg_home_client_config" \
    --address 10.83.0.50/32 \
    --private-key-file "$private_key_file" \
    --server-public-key test-server-pubkey

  [ "$status" -eq 0 ]
  [[ "$output" == *"Address = 10.83.0.50/32"* ]]
}

@test "rejects an unknown inventory peer" {
  run "$wg_home_client_config" \
    --peer nope \
    --private-key-file "$private_key_file" \
    --server-public-key test-server-pubkey

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown inventory peer 'nope'"* ]]
}

@test "rejects an address outside the home subnet" {
  run "$wg_home_client_config" \
    --address 10.84.0.50/32 \
    --private-key-file "$private_key_file" \
    --server-public-key test-server-pubkey

  [ "$status" -ne 0 ]
  [[ "$output" == *"is not inside 10.83.0.0/24"* ]]
}
