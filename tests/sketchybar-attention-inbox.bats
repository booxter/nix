#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="$PWD/home-manager/_mixins/sketchybar/sketchybar/plugins/attention-inbox.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/attention-inbox"
  cat >>"$tmpdir/bin/attention-inbox" <<'EOF'
printf '%s\n' "$*" >"$ATTENTION_INBOX_TEST_ARGS"
if [[ -n "${ATTENTION_INBOX_TEST_FAILURE:-}" ]]; then
  exit 1
fi
cat "$ATTENTION_INBOX_TEST_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/attention-inbox" "$tmpdir/bin/sketchybar"

  export NAME=attention.inbox
  export ATTENTION_INBOX_TEST_ARGS="$tmpdir/attention-inbox-args"
  export ATTENTION_INBOX_TEST_RESPONSE="$tmpdir/inbox.json"
  export ATTENTION_INBOX_NOW_EPOCH=1784203200
}

teardown() {
  rm -rf "$tmpdir"
}

write_inbox() {
  jq -n --argjson items "$1" '{schema_version: 1, items: $items}' \
    >"$ATTENTION_INBOX_TEST_RESPONSE"
}

@test "hides the item and popup rows when the inbox is empty" {
  write_inbox '[]'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set attention.inbox drawing=off popup.drawing=off"* ]]
  [[ "$output" == *"--set attention.inbox.0 drawing=off click_script="* ]]
  run grep -Fx -- '--format=json' "$ATTENTION_INBOX_TEST_ARGS"
  [ "$status" -eq 0 ]
}

@test "shows the total without a new marker for older pending items" {
  write_inbox '[
    {
      "id": "gitlab:1",
      "source": "gitlab",
      "reason": "assigned",
      "context": "tools/widget",
      "reference": "!41",
      "title": "Older item",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/41",
      "created_at": "2026-07-12T23:59:59Z"
    },
    {
      "id": "gitlab:2",
      "source": "gitlab",
      "reason": "mentioned",
      "context": "tools/widget",
      "reference": "!40",
      "title": "Another older item",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/40",
      "created_at": "2026-07-01T12:00:00Z"
    }
  ]'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set attention.inbox drawing=on label=2 label.color=0xffff9e64 icon.drawing=off"* ]]
  [[ "$output" == *"--set attention.inbox.0 drawing=on"* ]]
  [[ "$output" == *"label=gitlab · assigned · tools/widget!41 · Older item"* ]]
}

@test "marks the total and popup rows created during the current week" {
  write_inbox '[
    {
      "id": "gitlab:1",
      "source": "gitlab",
      "reason": "approval_required",
      "context": "tools/widget",
      "reference": "!42",
      "title": "Review this week",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/42",
      "created_at": "2026-07-14T08:00:00.123Z"
    },
    {
      "id": "gitlab:2",
      "source": "gitlab",
      "reason": "assigned",
      "context": "tools/widget",
      "reference": "!41",
      "title": "Review from last week",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/41",
      "created_at": "2026-07-12T08:00:00Z"
    }
  ]'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set attention.inbox drawing=on label=2 label.color=0xffff9e64 icon.drawing=on icon=● icon.color=0xffe0af68"* ]]
  [[ "$output" == *"--set attention.inbox.0 drawing=on"*"icon.drawing=on icon=●"* ]]
  [[ "$output" == *"--set attention.inbox.1 drawing=on"*"icon.drawing=off"* ]]
}

@test "uses the local calendar week near a UTC week boundary" {
  export ATTENTION_INBOX_NOW_EPOCH=1783904400
  write_inbox '[
    {
      "id": "gitlab:1",
      "source": "gitlab",
      "reason": "assigned",
      "context": "tools/widget",
      "reference": "!42",
      "title": "Sunday evening local time",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/42",
      "created_at": "2026-07-12T23:00:00Z"
    }
  ]'

  run env TZ='EST5EDT,M3.2.0,M11.1.0' PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"icon.drawing=on icon=● icon.color=0xffe0af68"* ]]
}

@test "limits the popup to ten clickable rows" {
  items="$(jq -n '[
    range(0; 11) as $index
    | {
        id: "gitlab:\($index)",
        source: "gitlab",
        reason: "assigned",
        context: "tools/widget",
        reference: "!\($index)",
        title: "Item \($index)",
        url: "https://gitlab.test/tools/widget/-/merge_requests/\($index)",
        created_at: "2026-07-01T12:00:00Z"
      }
  ]')"
  write_inbox "$items"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set attention.inbox drawing=on label=11 label.color=0xfff7768e"* ]]
  [[ "$output" == *"--set attention.inbox.9 drawing=on"* ]]
  [[ "$output" == *"label=gitlab · assigned · tools/widget!9 · Item 9"* ]]
  [[ "$output" == *"click_script=/usr/bin/open https://gitlab.test/tools/widget/-/merge_requests/9; sketchybar --set attention.inbox popup.drawing=off"* ]]
  [[ "$output" != *"attention.inbox.10"* ]]
  [[ "$output" != *"Item 10"* ]]
}

@test "keeps an exact count of ten orange" {
  items="$(jq -n '[
    range(0; 10) as $index
    | {
        id: "gitlab:\($index)",
        source: "gitlab",
        reason: "assigned",
        title: "Item \($index)",
        created_at: "2026-07-01T12:00:00Z"
      }
  ]')"
  write_inbox "$items"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set attention.inbox drawing=on label=10 label.color=0xffff9e64"* ]]
}

@test "shell-quotes popup URLs before assigning click scripts" {
  write_inbox '[
    {
      "id": "gitlab:1",
      "source": "gitlab",
      "reason": "assigned",
      "context": "tools/widget",
      "reference": "!42",
      "title": "Query URL",
      "url": "https://gitlab.test/tools/widget/-/merge_requests/42?tab=notes&sort=asc",
      "created_at": "2026-07-01T12:00:00Z"
    }
  ]'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *'click_script=/usr/bin/open https://gitlab.test/tools/widget/-/merge_requests/42\?tab=notes\&sort=asc; sketchybar --set attention.inbox popup.drawing=off'* ]]
  [[ "$output" != *'42?tab=notes&sort=asc; sketchybar'* ]]
}

@test "shows an error state when collection fails" {
  export ATTENTION_INBOX_TEST_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on popup.drawing=off icon.drawing=on icon=!"* ]]
  [[ "$output" == *"label=? label.color=0xffe0af68"* ]]
  [[ "$output" == *"--set attention.inbox.0 drawing=off"* ]]
}

@test "shows an error state for malformed JSON" {
  printf '%s\n' '{"items":"invalid"}' >"$ATTENTION_INBOX_TEST_RESPONSE"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on popup.drawing=off icon.drawing=on icon=!"* ]]
  [[ "$output" == *"label=? label.color=0xffe0af68"* ]]
}
