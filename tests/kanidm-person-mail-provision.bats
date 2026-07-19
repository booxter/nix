#!/usr/bin/env bats

setup() {
  script="${BATS_TEST_DIRNAME}/../nixos/pki/kanidm-person-mail-provision.sh"
}

@test "renders person mail addresses as Kanidm provisioning JSON" {
  first_mail="${BATS_TEST_TMPDIR}/first-mail"
  second_mail="${BATS_TEST_TMPDIR}/second-mail"
  provision_file="${BATS_TEST_TMPDIR}/persons.json"
  printf '%s\n' 'first@example.invalid' > "$first_mail"
  printf '%s\r\n' 'second+tag@example.invalid' > "$second_mail"

  run bash "$script" \
    "$provision_file" \
    alpha "$first_mail" \
    beta-user "$second_mail"
  [ "$status" -eq 0 ]

  run jq --exit-status '
    . == {
      persons: {
        alpha: {mailAddresses: ["first@example.invalid"]},
        "beta-user": {mailAddresses: ["second+tag@example.invalid"]}
      }
    }
  ' "$provision_file"
  [ "$status" -eq 0 ]
}

@test "rejects an empty mail address file" {
  empty_mail="${BATS_TEST_TMPDIR}/empty-mail"
  provision_file="${BATS_TEST_TMPDIR}/persons.json"
  : > "$empty_mail"

  run bash "$script" "$provision_file" alpha "$empty_mail"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mail address file is empty or missing for alpha"* ]]
}

@test "rejects incomplete person and mail file pairs" {
  provision_file="${BATS_TEST_TMPDIR}/persons.json"

  run bash "$script" "$provision_file" alpha
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
}
