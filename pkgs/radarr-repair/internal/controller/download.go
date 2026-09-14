package controller

import (
	"context"
	"strings"
	"time"
)

type DownloadReader interface {
	FindDownload(context.Context, string) (Download, bool, error)
}

type DownloadClient string

const (
	DownloadClientTransmission DownloadClient = "transmission"
	DownloadClientSABnzbd      DownloadClient = "sabnzbd"
)

type DownloadSourceType string

const (
	DownloadSourceTorrent DownloadSourceType = "torrent"
	DownloadSourceUsenet  DownloadSourceType = "usenet"
)

type DownloadIDComparison string

const (
	DownloadIDExact            DownloadIDComparison = "exact"
	DownloadIDASCIIInsensitive DownloadIDComparison = "ascii_insensitive"
)

type DownloadContentOwnership string

const (
	DownloadContentManifest   DownloadContentOwnership = "manifest"
	DownloadContentOutputTree DownloadContentOwnership = "output_tree"
)

type Download struct {
	Client           DownloadClient
	SourceType       DownloadSourceType
	ID               string
	IDComparison     DownloadIDComparison
	Name             string
	Stable           bool
	Complete         bool
	OutputPath       string
	Labels           []string
	CreatedAt        *time.Time
	AddedAt          *time.Time
	CompletedAt      *time.Time
	TotalSizeBytes   int64
	ContentOwnership DownloadContentOwnership
	Files            []DownloadFile
}

func (download Download) MatchesID(value string) bool {
	switch download.IDComparison {
	case DownloadIDExact:
		return value == download.ID
	case DownloadIDASCIIInsensitive:
		return strings.EqualFold(value, download.ID)
	default:
		return false
	}
}

type DownloadFile struct {
	Index          int
	HasIndex       bool
	Path           string
	LengthBytes    int64
	BytesCompleted int64
	Selected       bool
}
