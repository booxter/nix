package jobs

import "fmt"

type QueueKey struct {
	QueueID    int64
	DownloadID string
}

func (job Job) QueueKey() QueueKey {
	return QueueKey{QueueID: job.QueueID, DownloadID: job.DownloadID}
}

func QueueKeys(list []Job) []QueueKey {
	keys := make([]QueueKey, len(list))
	for i, job := range list {
		keys[i] = job.QueueKey()
	}
	return keys
}

// Match a saved job to at most one current row. Two movies or albums can
// share a download, so following a changed queue ID requires agreement in
// both directions.
func MatchSavedJobs(saved []Job, present []QueueKey) (map[QueueKey]Job, error) {
	previous := QueueKeys(saved)
	matches := make(map[QueueKey]Job)
	for i := range previous {
		row, owned, err := matchSavedJob(i, previous, present)
		if err != nil {
			return nil, err
		}
		if owned {
			matches[present[row]] = saved[i]
		}
	}
	return matches, nil
}

func matchSavedJob(index int, previous, present []QueueKey) (row int, owned bool, err error) {
	row, err = MatchQueue(previous[index], present)
	if err != nil || row < 0 {
		return row, false, err
	}
	owner, err := MatchQueue(present[row], previous)
	return row, owner == index, err
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
