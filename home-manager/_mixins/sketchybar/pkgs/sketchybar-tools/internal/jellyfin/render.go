package jellyfin

import (
	"fmt"
	"strings"
)

const maxPopupSessions = 8

type ScopeAggregate struct {
	Active  int
	Bitrate int64
	Missing int
}

func SessionLabel(session Session) string {
	device := session.Device
	if device == "" {
		device = session.Client
	}
	if device == "" {
		device = "Unknown device"
	}
	username := session.Username
	if username == "" {
		username = "Unknown"
	}
	media := session.Title
	if session.MediaType == "Episode" {
		code := episodeCode(session.SeriesSeason, session.SeriesEpisode)
		if session.SeriesTitle != "" {
			media = session.SeriesTitle
		}
		if code != "" {
			media += " " + code
		}
		if session.SeriesTitle != "" && session.Title != "" && session.Title != session.SeriesTitle {
			media += " — " + session.Title
		}
	} else if media == "" {
		media = session.MediaType
	}

	timing := "playing"
	if !session.Playing {
		switch {
		case session.Progress != nil:
			timing = fmt.Sprintf("paused at %d%%", *session.Progress)
		case session.Remaining != nil:
			timing = "paused · " + formatRemaining(*session.Remaining)
		default:
			timing = "paused"
		}
	} else if session.Remaining != nil {
		timing = formatRemaining(*session.Remaining)
	} else if session.Progress != nil {
		timing = fmt.Sprintf("%d%%", *session.Progress)
	}

	label := fmt.Sprintf("%s · %s · %s · %s — %s", session.Scope, username, device, media, timing)
	if method := methodLabel(session.Method); method != "" {
		label += " · " + method
	}
	if session.Bitrate != nil && *session.Bitrate != 0 {
		label += " · " + formatBitrate(*session.Bitrate)
	}
	return label
}

func AggregateBandwidth(sessions []Session) string {
	aggregates := map[string]ScopeAggregate{
		"WAN": {},
		"LAN": {},
	}
	for _, session := range sessions {
		if !session.Playing {
			continue
		}
		scope := session.Scope
		if scope != "WAN" && scope != "LAN" {
			scope = "Unknown"
		}
		aggregate := aggregates[scope]
		aggregate.Active++
		if session.Bitrate != nil && *session.Bitrate > 0 {
			aggregate.Bitrate += *session.Bitrate
		} else {
			aggregate.Missing++
		}
		aggregates[scope] = aggregate
	}
	parts := []string{
		formatScopeBitrate("WAN", aggregates["WAN"]),
		formatScopeBitrate("LAN", aggregates["LAN"]),
	}
	if aggregates["Unknown"].Active > 0 {
		parts = append(parts, formatScopeBitrate("Unknown", aggregates["Unknown"]))
	}
	return strings.Join(parts, " · ")
}

func formatRemaining(seconds int64) string {
	if seconds < 60 {
		return "<1m left"
	}
	minutes := (seconds + 59) / 60
	if minutes < 60 {
		return fmt.Sprintf("%dm left", minutes)
	}
	hours := minutes / 60
	minutes %= 60
	if minutes == 0 {
		return fmt.Sprintf("%dh left", hours)
	}
	return fmt.Sprintf("%dh %02dm left", hours, minutes)
}

func formatBitrate(bitsPerSecond int64) string {
	if bitsPerSecond%1_000_000 == 0 {
		return fmt.Sprintf("%d Mbit", bitsPerSecond/1_000_000)
	}
	return fmt.Sprintf("%.1f Mbit", float64(bitsPerSecond)/1_000_000)
}

func formatScopeBitrate(scope string, aggregate ScopeAggregate) string {
	if aggregate.Active == 0 {
		return scope + " 0 Mbit"
	}
	if aggregate.Missing > 0 {
		if aggregate.Bitrate > 0 {
			return scope + " ≥" + formatBitrate(aggregate.Bitrate)
		}
		return scope + " ?"
	}
	return scope + " " + formatBitrate(aggregate.Bitrate)
}

func episodeCode(season, episode string) string {
	code := ""
	if season != "" {
		if strings.HasPrefix(strings.ToLower(season), "s") {
			code = season
		} else {
			code = "S" + season
		}
	}
	if episode != "" {
		if strings.HasPrefix(strings.ToLower(episode), "e") {
			code += episode
		} else {
			code += "E" + episode
		}
	}
	return code
}

func methodLabel(method string) string {
	switch strings.ToLower(method) {
	case "directplay":
		return "direct"
	case "directstream":
		return "direct stream"
	case "transcode":
		return "transcode"
	default:
		return method
	}
}
