package lidarrcontracts

import "time"

const SchemaVersion = "lidarr-repair/v2"

type Case struct {
	SchemaVersion string       `json:"schema_version"`
	CaseID        string       `json:"case_id"`
	ObservedAt    time.Time    `json:"observed_at"`
	Queue         Queue        `json:"queue"`
	Album         Album        `json:"album"`
	Releases      []Release    `json:"releases"`
	Tracks        []Track      `json:"tracks"`
	Artifacts     []Artifact   `json:"artifacts"`
	Assessments   []Assessment `json:"assessments"`
	Capabilities  []Capability `json:"capabilities"`
}

type Queue struct {
	QueueID     int64    `json:"queue_id"`
	Title       string   `json:"title"`
	DownloadRef string   `json:"download_ref"`
	Messages    []string `json:"messages"`
}

type Album struct {
	AlbumID   int64  `json:"album_id"`
	ArtistID  int64  `json:"artist_id"`
	Artist    string `json:"artist"`
	Title     string `json:"title"`
	Monitored bool   `json:"monitored"`
}

type Release struct {
	ReleaseID        int64    `json:"release_id"`
	ForeignReleaseID string   `json:"foreign_release_id"`
	Title            string   `json:"title"`
	Disambiguation   string   `json:"disambiguation"`
	Format           string   `json:"format"`
	Countries        []string `json:"countries"`
	Labels           []string `json:"labels"`
	TrackCount       int      `json:"track_count"`
	MediumCount      int      `json:"medium_count"`
	Monitored        bool     `json:"monitored"`
}

type Track struct {
	TrackID        int64  `json:"track_id"`
	ReleaseID      int64  `json:"release_id"`
	Number         string `json:"number"`
	AbsoluteNumber int    `json:"absolute_number"`
	MediumNumber   int    `json:"medium_number"`
	Title          string `json:"title"`
	DurationMS     int    `json:"duration_ms"`
	HasFile        bool   `json:"has_file"`
}

type Tag struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type Stream struct {
	Kind         string  `json:"kind"`
	Codec        *string `json:"codec"`
	SampleRateHz *int64  `json:"sample_rate_hz"`
	Channels     *int64  `json:"channels"`
	BitRateBPS   *int64  `json:"bit_rate_bps"`
}

type Artifact struct {
	ArtifactID   string   `json:"artifact_id"`
	RelativePath string   `json:"relative_path"`
	Fingerprint  string   `json:"fingerprint"`
	SizeBytes    int64    `json:"size_bytes"`
	DurationMS   *int64   `json:"duration_ms"`
	Formats      []string `json:"formats"`
	Tags         []Tag    `json:"tags"`
	Streams      []Stream `json:"streams"`
}

type Assessment struct {
	ArtifactID      string   `json:"artifact_id"`
	AlbumID         *int64   `json:"album_id"`
	ReleaseID       *int64   `json:"release_id"`
	TrackIDs        []int64  `json:"track_ids"`
	TagTitle        *string  `json:"tag_title"`
	TagArtist       *string  `json:"tag_artist"`
	TagAlbum        *string  `json:"tag_album"`
	TagTrackNumbers []int    `json:"tag_track_numbers"`
	Rejections      []string `json:"rejections"`
}

type Capability struct {
	Action       string   `json:"action"`
	CapabilityID string   `json:"capability_id"`
	AlbumID      int64    `json:"album_id"`
	ArtifactIDs  []string `json:"artifact_ids"`
	ReleaseID    int64    `json:"release_id"`
	TrackIDs     []int64  `json:"track_ids"`
}

type DecisionAction string

const (
	ActionNoRepair            DecisionAction = "no_repair"
	ActionImportMissingTracks DecisionAction = "import_missing_tracks_v1"
)

type Decision struct {
	Kind                DecisionAction
	NoRepair            *NoRepairDecision
	ImportMissingTracks *ImportMissingTracksDecision
}

func (decision Decision) CaseID() string {
	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair.CaseID
		}
	case ActionImportMissingTracks:
		if decision.ImportMissingTracks != nil {
			return decision.ImportMissingTracks.CaseID
		}
	}
	return ""
}

type NoRepairDecision struct {
	SchemaVersion string   `json:"schema_version"`
	CaseID        string   `json:"case_id"`
	Action        string   `json:"action"`
	Reason        string   `json:"reason"`
	EvidenceRefs  []string `json:"evidence_refs"`
	Explanation   string   `json:"explanation"`
}

type TrackMapping struct {
	ArtifactID string `json:"artifact_id"`
	TrackID    int64  `json:"track_id"`
}

type ImportMissingTracksDecision struct {
	SchemaVersion string         `json:"schema_version"`
	CaseID        string         `json:"case_id"`
	Action        string         `json:"action"`
	CapabilityID  string         `json:"capability_id"`
	AlbumID       int64          `json:"album_id"`
	ReleaseID     int64          `json:"release_id"`
	Mappings      []TrackMapping `json:"mappings"`
	EvidenceRefs  []string       `json:"evidence_refs"`
	Explanation   string         `json:"explanation"`
}
