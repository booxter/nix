{
  coreutils,
  curl,
  jq,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "kanidm-mail-sender-bootstrap";
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = ''
    usage() {
      cat <<'USAGE'
    Usage: kanidm-mail-sender-bootstrap --url URL --idm-admin-password-file PATH --token-file PATH --token-owner USER --token-group GROUP [--accept-invalid-certs]

    Options:
      --accept-invalid-certs        Disable TLS certificate verification for the Kanidm API connection.
      -h, --help                    Show this help.
    USAGE
    }

    die() {
      echo "kanidm-mail-sender-bootstrap: $*" >&2
      exit 1
    }

    kanidm_url=
    idm_admin_password_file=
    token_file=
    token_owner=
    token_group=
    account=mail-sender
    display_name="Kanidm Mail Sender"
    entry_managed_by=idm_admins
    message_sender_group=idm_message_senders
    token_label="mail sender token"
    accept_invalid_certs=false

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --url)
          kanidm_url="''${2:-}"
          shift 2
          ;;
        --idm-admin-password-file)
          idm_admin_password_file="''${2:-}"
          shift 2
          ;;
        --token-file)
          token_file="''${2:-}"
          shift 2
          ;;
        --token-owner)
          token_owner="''${2:-}"
          shift 2
          ;;
        --token-group)
          token_group="''${2:-}"
          shift 2
          ;;
        --accept-invalid-certs)
          accept_invalid_certs=true
          shift
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          die "unknown argument: $1"
          ;;
      esac
    done

    [ -n "$kanidm_url" ] || die "missing --url"
    [ -n "$idm_admin_password_file" ] || die "missing --idm-admin-password-file"
    [ -n "$token_file" ] || die "missing --token-file"
    [ -n "$token_owner" ] || die "missing --token-owner"
    [ -n "$token_group" ] || die "missing --token-group"
    [ -r "$idm_admin_password_file" ] || die "cannot read idm admin password file: $idm_admin_password_file"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    headers="$tmpdir/headers"
    body="$tmpdir/body.json"

    curl_common=(
      --silent
      --show-error
      --location
      --max-time 15
      --connect-timeout 5
    )
    curl_fail=(--fail "''${curl_common[@]}")
    curl_tls=()
    if [ "$accept_invalid_certs" = true ]; then
      curl_tls=(--insecure)
    fi

    curl_auth=()

    auth_request() {
      curl "''${curl_fail[@]}" "''${curl_tls[@]}" \
        -H "Content-Type: application/json" \
        "''${curl_auth[@]}" \
        "$@"
    }

    curl "''${curl_fail[@]}" "''${curl_tls[@]}" \
      --dump-header "$headers" \
      --output /dev/null \
      -H "Content-Type: application/json" \
      --request POST \
      "$kanidm_url/v1/auth" \
      --data-binary '{"step":{"init":"idm_admin"}}'

    session_id=
    while IFS= read -r line; do
      case "$line" in
        X-KANIDM-AUTH-SESSION-ID:*|x-kanidm-auth-session-id:*)
          session_id="''${line#*:}"
          session_id="''${session_id#"''${session_id%%[![:space:]]*}"}"
          session_id="''${session_id%$'\r'}"
          break
          ;;
      esac
    done < "$headers"
    [ -n "$session_id" ] || die "Kanidm auth init did not return a session id"

    curl "''${curl_fail[@]}" "''${curl_tls[@]}" \
      --output /dev/null \
      -H "Content-Type: application/json" \
      -H "X-KANIDM-AUTH-SESSION-ID: $session_id" \
      --request POST \
      "$kanidm_url/v1/auth" \
      --data-binary '{"step":{"begin":"password"}}'

    jq -n --rawfile password "$idm_admin_password_file" \
      '{step:{cred:{password:($password | sub("\n$"; ""))}}}' > "$body"
    auth_response="$(
      curl "''${curl_fail[@]}" "''${curl_tls[@]}" \
        -H "Content-Type: application/json" \
        -H "X-KANIDM-AUTH-SESSION-ID: $session_id" \
        --request POST \
        "$kanidm_url/v1/auth" \
        --data-binary @"$body"
    )"
    bearer_token="$(jq -r '.state.success // empty' <<< "$auth_response")"
    [ -n "$bearer_token" ] || die "Kanidm auth did not return a bearer token"
    curl_auth=(
      -H "X-KANIDM-AUTH-SESSION-ID: $session_id"
      -H "Authorization: Bearer $bearer_token"
    )

    service_account_status="$(
      curl "''${curl_common[@]}" "''${curl_tls[@]}" \
        --output "$tmpdir/service-account.json" \
        --write-out '%{http_code}' \
        -H "Content-Type: application/json" \
        "''${curl_auth[@]}" \
        "$kanidm_url/v1/service_account/$account"
    )" || die "failed to query service account $account"

    case "$service_account_status" in
      200)
        if jq -e 'type == "object"' "$tmpdir/service-account.json" >/dev/null; then
          echo "service account already exists: $account"
        else
          service_account_status=404
        fi
        ;;
    esac

    case "$service_account_status" in
      200)
        ;;
      404)
        jq -n \
          --arg name "$account" \
          --arg display_name "$display_name" \
          --arg entry_managed_by "$entry_managed_by" \
          '{attrs:{name:[$name],displayname:[$display_name],entry_managed_by:[$entry_managed_by]}}' \
          > "$body"
        auth_request \
          --output /dev/null \
          --request POST \
          "$kanidm_url/v1/service_account" \
          --data-binary @"$body"
        echo "created service account: $account"
        ;;
      *)
        cat "$tmpdir/service-account.json" >&2 || true
        die "unexpected status while querying service account $account: $service_account_status"
        ;;
    esac

    members_json="$(
      auth_request \
        --request GET \
        "$kanidm_url/v1/group/$message_sender_group/_attr/member"
    )"
    if jq -e --arg account "$account" '(. // []) | map(split("@")[0]) | index($account)' \
      <<< "$members_json" >/dev/null; then
      echo "service account already in group: $message_sender_group"
    else
      jq -n --arg account "$account" '[$account]' > "$body"
      auth_request \
        --output /dev/null \
        --request POST \
        "$kanidm_url/v1/group/$message_sender_group/_attr/member" \
        --data-binary @"$body"
      echo "added $account to $message_sender_group"
    fi

    token_dir="$(dirname "$token_file")"
    install -d -m 0700 -o "$token_owner" -g "$token_group" "$token_dir"

    if [ -s "$token_file" ]; then
      echo "mail sender API token file already exists: $token_file"
      exit 0
    fi

    jq -n --arg label "$token_label" \
      '{label:$label,expiry:null,read_write:true,compact:false}' > "$body"
    token_response="$(
      auth_request \
        --request POST \
        "$kanidm_url/v1/service_account/$account/_api_token" \
        --data-binary @"$body"
    )"
    api_token="$(jq -r 'if type == "string" then . else empty end' <<< "$token_response")"
    [ -n "$api_token" ] || die "Kanidm did not return an API token"

    printf '%s\n' "$api_token" > "$tmpdir/token"
    install -m 0400 -o "$token_owner" -g "$token_group" "$tmpdir/token" "$token_file"
    echo "created mail sender API token file: $token_file"
  '';

  meta = {
    description = "Bootstrap the Kanidm mail sender service account and local API token file";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "kanidm-mail-sender-bootstrap";
    platforms = lib.platforms.linux;
  };
}
