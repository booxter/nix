package controller

import (
	"context"
	"time"
)

type TransmissionReader interface {
	FindTorrent(context.Context, string) (TransmissionTorrent, bool, error)
}

type TransmissionStatus int

type TransmissionTorrent struct {
	Hash              string
	Name              string
	Status            TransmissionStatus
	PercentDone       float64
	LeftUntilDone     int64
	Finished          bool
	DownloadDirectory string
	Labels            []string
	CreatedAt         *time.Time
	AddedAt           *time.Time
	CompletedAt       *time.Time
	TotalSizeBytes    int64
	Files             []TransmissionFile
}

type TransmissionFile struct {
	Index          int
	Name           string
	LengthBytes    int64
	BytesCompleted int64
	Wanted         bool
	Priority       int
}
