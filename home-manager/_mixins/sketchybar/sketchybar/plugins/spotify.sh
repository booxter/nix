#!/usr/bin/env bash

next ()
{
  osascript -e 'tell application "Spotify" to play next track'
}

back () 
{
  osascript -e 'tell application "Spotify" to play previous track'
}

play () 
{
  osascript -e 'tell application "Spotify" to playpause'
}

repeat () 
{
  REPEAT=$(osascript -e 'tell application "Spotify" to get repeating')
  if [ "$REPEAT" = "false" ]; then
    sketchybar -m --set spotify.repeat icon.highlight=on
    osascript -e 'tell application "Spotify" to set repeating to true'
  else 
    sketchybar -m --set spotify.repeat icon.highlight=off
    osascript -e 'tell application "Spotify" to set repeating to false'
  fi
}

shuffle () 
{
  SHUFFLE=$(osascript -e 'tell application "Spotify" to get shuffling')
  if [ "$SHUFFLE" = "false" ]; then
    sketchybar -m --set spotify.shuffle icon.highlight=on
    osascript -e 'tell application "Spotify" to set shuffling to true'
  else 
    sketchybar -m --set spotify.shuffle icon.highlight=off
    osascript -e 'tell application "Spotify" to set shuffling to false'
  fi
}

spotify_info_field ()
{
  # Keep truncation UTF-8 aware; cut can split bytes under SketchyBar's launch locale.
  jq -r --arg field "$1" '.[$field] // "" | .[:20]' <<<"$INFO"
}

update ()
{
  PLAYING=1
  if [ "$(jq -r '.["Player State"] // ""' <<<"$INFO")" = "Playing" ]; then
    PLAYING=0
    TRACK="$(spotify_info_field Name)"
    ARTIST="$(spotify_info_field Artist)"
    ALBUM="$(spotify_info_field Album)"
    SHUFFLE=$(osascript -e 'tell application "Spotify" to get shuffling')
    REPEAT=$(osascript -e 'tell application "Spotify" to get repeating')
  fi

  args=()
  if [ "$PLAYING" -eq 0 ]; then
    if [ -z "$ARTIST" ]; then
      args+=(--set spotify.name label="􀑪 $TRACK 􀉮 $ALBUM" drawing=on)
    else
      args+=(--set spotify.name label="􀑪 $TRACK 􀉮 $ARTIST" drawing=on)
    fi
    args+=(--set spotify.play icon=􀊆 \
           --set spotify.shuffle icon.highlight="$SHUFFLE" \
           --set spotify.repeat icon.highlight="$REPEAT")
  else
    args+=(--set spotify.name drawing=off \
           --set spotify.name popup.drawing=off \
           --set spotify.play icon=􀊄)
  fi
  sketchybar -m "${args[@]}"
}

mouse_clicked () {
  case "$NAME" in
    "spotify.next") next
    ;;
    "spotify.back") back
    ;;
    "spotify.play") play
    ;;
    "spotify.shuffle") shuffle
    ;;
    "spotify.repeat") repeat
    ;;
    *) exit
    ;;
  esac
}

case "$SENDER" in
  "mouse.clicked") mouse_clicked
  ;;
  "forced") exit
  ;;
  *) update
  ;;
esac
