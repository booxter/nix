package jobs

import "fmt"

type QueueKey struct {
	QueueID    int64
	DownloadID string
}

func (job Job) QueueKey() QueueKey {
	return QueueKey{QueueID: job.QueueID, DownloadID: job.DownloadID}
}

// MatchQueue prefers the current row, but follows a changed row ID only when
// the download has a single candidate. Callers scope candidates to one service.
func MatchQueue(wanted QueueKey, candidates []QueueKey) (int, error) {
	match := -1
	count := 0
	for index, candidate := range candidates {
		if candidate == wanted {
			return index, nil
		}
		if wanted.DownloadID != "" && candidate.DownloadID == wanted.DownloadID {
			match = index
			count++
		}
	}
	if count > 1 {
		return -1, fmt.Errorf("download matches multiple queue entries; cannot follow changed queue ID")
	}
	return match, nil
}
