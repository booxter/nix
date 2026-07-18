# shellcheck shell=bash

set -euo pipefail

if (( $# < 3 || ($# - 1) % 2 != 0 )); then
  echo "usage: kanidm-person-mail-provision OUTPUT PERSON MAIL_FILE [PERSON MAIL_FILE ...]" >&2
  exit 2
fi

output=$1
shift
output_dir="$(dirname -- "$output")"
if [[ ! -d "$output_dir" ]]; then
  echo "output directory does not exist: $output_dir" >&2
  exit 1
fi

umask 077
tmp="$(mktemp "$output_dir/.persons.json.XXXXXX")"
next=""
cleanup() {
  [[ -z "$next" ]] || rm -f -- "$next"
  [[ -z "$tmp" ]] || rm -f -- "$tmp"
}
trap cleanup EXIT

printf '{"persons":{}}\n' > "$tmp"
while (( $# > 0 )); do
  person=$1
  mail_file=$2
  shift 2

  if [[ ! -s "$mail_file" ]]; then
    echo "mail address file is empty or missing for $person: $mail_file" >&2
    exit 1
  fi

  next="$(mktemp "$output_dir/.persons.json.XXXXXX")"
  jq \
    --arg person "$person" \
    --rawfile mail "$mail_file" \
    '($mail | sub("[\r\n]+$"; "")) as $mail
     | if ($mail | length) == 0 then
         error("empty mail address for " + $person)
       else
         .persons[$person].mailAddresses = [$mail]
       end' \
    "$tmp" > "$next"
  mv -- "$next" "$tmp"
  next=""
done

mv -- "$tmp" "$output"
tmp=""
trap - EXIT
