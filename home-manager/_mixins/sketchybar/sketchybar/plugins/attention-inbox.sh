#!/usr/bin/env bash

set -euo pipefail

ITEM="attention.inbox"
POPUP_ITEM_PREFIX="attention.inbox."
MAX_ITEMS=10

NEUTRAL="0xffa9b1d6"
ORANGE="0xffff9e64"
RED="0xfff7768e"
YELLOW="0xffe0af68"

hide_popup_items() {
  local args=()
  local index

  for ((index = 0; index < MAX_ITEMS; index++)); do
    args+=(
      --set "${POPUP_ITEM_PREFIX}${index}"
      drawing=off
      click_script=
    )
  done
  sketchybar "${args[@]}"
}

hide_inbox() {
  sketchybar --set "$ITEM" drawing=off popup.drawing=off
  hide_popup_items
}

show_error() {
  sketchybar --set "$ITEM" \
    drawing=on \
    popup.drawing=off \
    icon.drawing=on \
    icon="!" \
    icon.color="$YELLOW" \
    label="?" \
    label.color="$YELLOW"
  hide_popup_items
}

attention_args=(--format=json)
if [[ -n "${ATTENTION_INBOX_GITLAB_HOSTNAME:-}" ]]; then
  attention_args+=(--gitlab-hostname "$ATTENTION_INBOX_GITLAB_HOSTNAME")
fi

if ! inbox="$("${ATTENTION_INBOX_BIN:-attention-inbox}" "${attention_args[@]}")"; then
  show_error
  exit 0
fi

now_epoch="${ATTENTION_INBOX_NOW_EPOCH:-$(date +%s)}"
if ! [[ "$now_epoch" =~ ^[0-9]+$ ]]; then
  show_error
  exit 0
fi

if ! view="$(jq --exit-status \
  --argjson now "$now_epoch" \
  --argjson limit "$MAX_ITEMS" '
    def timezone_offset($epoch):
      ($epoch | localtime | mktime) - $epoch;
    def week_start($epoch):
      ($epoch | localtime) as $parts
      | ((($parts[6] + 6) % 7)) as $days_since_monday
      | (
          $parts
          | .[2] -= $days_since_monday
          | .[3] = 0
          | .[4] = 0
          | .[5] = 0
          | mktime
        ) as $local_monday
      | ($local_monday - timezone_offset($epoch)) as $estimate
      | $local_monday - timezone_offset($estimate);
    def created_epoch:
      if type != "string" then
        null
      else
        try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
      end;
    def is_new($start):
      (.created_at | created_epoch) as $created
      | $created != null and $created >= $start;
    def clean:
      tostring | gsub("[\\r\\n\\t]+"; " ");
    def truncate($length):
      if length <= $length then . else .[0:($length - 1)] + "…" end;

    if type != "object" or (.items | type) != "array" then
      error("expected an inbox object with an items array")
    else
      week_start($now) as $start
      | {
          total: (.items | length),
          new_count: ([.items[] | select(is_new($start))] | length),
          items: [
            .items[:$limit][]
            | . as $item
            | {
                is_new: is_new($start),
                url: (($item.url // "") | clean),
                label: (
                  [
                    (($item.source // "unknown") | clean),
                    (($item.reason // "item") | gsub("_"; " ") | clean),
                    ((($item.context // "") + ($item.reference // "")) | clean),
                    (($item.title // "Untitled item") | clean)
                  ]
                  | map(select(length > 0))
                  | join(" · ")
                  | truncate(100)
                )
              }
          ]
        }
    end
  ' <<<"$inbox" 2>/dev/null)"; then
  show_error
  exit 0
fi

total="$(jq -r '.total' <<<"$view")"
if ((total == 0)); then
  hide_inbox
  exit 0
fi

new_count="$(jq -r '.new_count' <<<"$view")"
row_count="$(jq -r '.items | length' <<<"$view")"
if ((total > 10)); then
  count_color="$RED"
else
  count_color="$ORANGE"
fi
args=(
  --set "$ITEM"
  drawing=on
  label="$total"
  label.color="$count_color"
)

if ((new_count > 0)); then
  args+=(
    icon.drawing=on
    icon="●"
    icon.color="$YELLOW"
  )
else
  args+=(icon.drawing=off)
fi

for ((index = 0; index < MAX_ITEMS; index++)); do
  popup_item="${POPUP_ITEM_PREFIX}${index}"
  args+=(--set "$popup_item")
  if ((index >= row_count)); then
    args+=(drawing=off click_script=)
    continue
  fi

  label="$(jq -r --argjson index "$index" '.items[$index].label' <<<"$view")"
  url="$(jq -r --argjson index "$index" '.items[$index].url' <<<"$view")"
  is_new="$(jq -r --argjson index "$index" '.items[$index].is_new' <<<"$view")"

  click_script=""
  if [[ -n "$url" ]]; then
    printf -v quoted_url '%q' "$url"
    click_script="/usr/bin/open $quoted_url; sketchybar --set $ITEM popup.drawing=off"
  fi

  args+=(
    drawing=on
    label="$label"
    label.color="$NEUTRAL"
    click_script="$click_script"
  )
  if [[ "$is_new" == "true" ]]; then
    args+=(
      icon.drawing=on
      icon="●"
      icon.color="$YELLOW"
      label.padding_left=4
    )
  else
    args+=(
      icon.drawing=off
      label.padding_left=8
    )
  fi
done

sketchybar "${args[@]}"
