package jellyfin

import (
	"fmt"
	"io"
	"math"
	"net"
	"net/netip"
	"sort"
	"strings"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

type Session struct {
	Playing       bool
	Scope         string
	Username      string
	Device        string
	Client        string
	MediaType     string
	Title         string
	SeriesTitle   string
	SeriesSeason  string
	SeriesEpisode string
	Method        string
	Progress      *int64
	Remaining     *int64
	Bitrate       *int64
}

type sessionKey struct {
	UserID        string
	Username      string
	Device        string
	MediaType     string
	Title         string
	SeriesTitle   string
	SeriesSeason  string
	SeriesEpisode string
	Method        string
}

type userKey struct {
	UserID   string
	Username string
	Device   string
}

type userDetails struct {
	Scope  string
	Client string
}

var supportedMediaTypes = map[string]bool{
	"Audio":      true,
	"AudioBook":  true,
	"Episode":    true,
	"Movie":      true,
	"MusicVideo": true,
	"Trailer":    true,
	"Video":      true,
}

func ParseMetrics(reader io.Reader) ([]Session, error) {
	parser := expfmt.NewTextParser(model.UTF8Validation)
	families, err := parser.TextToMetricFamilies(reader)
	if err != nil {
		return nil, fmt.Errorf("parse Jellyfin metrics: %w", err)
	}
	if metricFamilyValue(families["jellyfin_up"], nil) != 1 {
		return nil, fmt.Errorf("Jellyfin is unavailable")
	}
	if metricFamilyValue(
		families["jellyfin_scrape_collector_success"],
		map[string]string{"collector": "playing"},
	) != 1 {
		return nil, fmt.Errorf("Jellyfin playing collector failed")
	}
	if metricFamilyValue(
		families["jellyfin_scrape_collector_success"],
		map[string]string{"collector": "users"},
	) != 1 {
		return nil, fmt.Errorf("Jellyfin users collector failed")
	}

	users := make(map[userKey]userDetails)
	for _, metric := range metrics(families["jellyfin_user_active"]) {
		labels := labels(metric)
		users[userKeyFromLabels(labels)] = userDetails{
			Scope:  addressScope(labels["ip_address"]),
			Client: labels["client"],
		}
	}

	sessions := make(map[sessionKey]Session)
	for _, metric := range metrics(families["jellyfin_now_playing_state"]) {
		labels := labels(metric)
		if !supportedMediaTypes[labels["type"]] {
			continue
		}
		key := sessionKeyFromLabels(labels)
		user := users[userKeyFromLabels(labels)]
		scope := user.Scope
		if scope == "" {
			scope = "unknown"
		}
		sessions[key] = Session{
			Playing:       metricValue(metric) > 0.5,
			Scope:         scope,
			Username:      key.Username,
			Device:        key.Device,
			Client:        user.Client,
			MediaType:     key.MediaType,
			Title:         key.Title,
			SeriesTitle:   key.SeriesTitle,
			SeriesSeason:  key.SeriesSeason,
			SeriesEpisode: key.SeriesEpisode,
			Method:        key.Method,
		}
	}

	progress := metricValuesBySession(families["jellyfin_now_playing_progress"])
	remaining := metricValuesBySession(families["jellyfin_now_playing_remaining"])
	bitrates := make(map[userKey]int64)
	for _, metric := range metrics(families["jellyfin_now_playing_bitrate_bits_per_second"]) {
		value := metricValue(metric)
		if value < 0 {
			return nil, fmt.Errorf("Jellyfin bitrate is negative")
		}
		bitrates[userKeyFromLabels(labels(metric))] = int64(math.Round(value))
	}

	result := make([]Session, 0, len(sessions))
	for key, session := range sessions {
		if value, found := progress[key]; found {
			session.Progress = pointer(value)
		}
		if value, found := remaining[key]; found {
			session.Remaining = pointer(value)
		}
		if value, found := bitrates[userKey{key.UserID, key.Username, key.Device}]; found {
			session.Bitrate = pointer(value)
		}
		result = append(result, session)
	}
	sort.Slice(result, func(left, right int) bool {
		leftKey := strings.ToLower(result[left].Username + "\x1f" + result[left].Device + "\x1f" + result[left].Title)
		rightKey := strings.ToLower(result[right].Username + "\x1f" + result[right].Device + "\x1f" + result[right].Title)
		return leftKey < rightKey
	})
	return result, nil
}

func metrics(family *dto.MetricFamily) []*dto.Metric {
	if family == nil {
		return nil
	}
	return family.GetMetric()
}

func metricFamilyValue(family *dto.MetricFamily, requiredLabels map[string]string) float64 {
	for _, metric := range metrics(family) {
		labels := labels(metric)
		matches := true
		for name, expected := range requiredLabels {
			if labels[name] != expected {
				matches = false
				break
			}
		}
		if matches {
			return metricValue(metric)
		}
	}
	return math.NaN()
}

func metricValue(metric *dto.Metric) float64 {
	switch {
	case metric.Gauge != nil:
		return metric.GetGauge().GetValue()
	case metric.Counter != nil:
		return metric.GetCounter().GetValue()
	case metric.Untyped != nil:
		return metric.GetUntyped().GetValue()
	default:
		return math.NaN()
	}
}

func labels(metric *dto.Metric) map[string]string {
	result := make(map[string]string, len(metric.GetLabel()))
	for _, pair := range metric.GetLabel() {
		result[pair.GetName()] = pair.GetValue()
	}
	return result
}

func sessionKeyFromLabels(labels map[string]string) sessionKey {
	return sessionKey{
		UserID:        labels["user_id"],
		Username:      labels["username"],
		Device:        labels["device"],
		MediaType:     labels["type"],
		Title:         labels["title"],
		SeriesTitle:   labels["series_title"],
		SeriesSeason:  labels["series_season"],
		SeriesEpisode: labels["series_episode"],
		Method:        labels["method"],
	}
}

func userKeyFromLabels(labels map[string]string) userKey {
	return userKey{
		UserID:   labels["user_id"],
		Username: labels["username"],
		Device:   labels["device"],
	}
}

func metricValuesBySession(family *dto.MetricFamily) map[sessionKey]int64 {
	result := make(map[sessionKey]int64)
	for _, metric := range metrics(family) {
		result[sessionKeyFromLabels(labels(metric))] = int64(math.Round(metricValue(metric)))
	}
	return result
}

func pointer(value int64) *int64 {
	return &value
}

func addressScope(endpoint string) string {
	host := endpoint
	if parsedHost, _, err := net.SplitHostPort(endpoint); err == nil {
		host = parsedHost
	}
	address, err := netip.ParseAddr(host)
	if err != nil {
		return "unknown"
	}
	address = address.Unmap()
	if address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() {
		return "LAN"
	}
	return "WAN"
}
