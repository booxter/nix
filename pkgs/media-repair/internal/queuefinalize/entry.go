package queuefinalize

import "strings"

type Entry struct {
	Protocol              string
	DownloadClient        string
	QueueID               int64
	DownloadID            string
	SubjectID             int64
	Status                string
	TrackedDownloadStatus string
}

func (entry Entry) Eligible() bool {
	return entry.QueueID > 0 && strings.TrimSpace(entry.DownloadID) != "" &&
		strings.TrimSpace(entry.DownloadID) == entry.DownloadID &&
		entry.SubjectID > 0 && entry.Status == "completed" &&
		entry.TrackedDownloadStatus == "warning"
}
