package queueaction

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

const RequestVersion = "media-repair-queue-action/v1"

type Service string

const (
	ServiceLidarr Service = "lidarr"
	ServiceRadarr Service = "radarr"
)

type Action string

const ActionRemoveTracking Action = "remove_tracking"

var fingerprintPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type QueueIdentity struct {
	QueueID               int64  `json:"queue_id"`
	DownloadID            string `json:"download_id"`
	SubjectID             int64  `json:"subject_id"`
	Status                string `json:"status"`
	TrackedDownloadStatus string `json:"tracked_download_status"`
}

func Identity(entry queuefinalize.Entry) QueueIdentity {
	return QueueIdentity{
		QueueID: entry.QueueID, DownloadID: entry.DownloadID, SubjectID: entry.SubjectID,
		Status: entry.Status, TrackedDownloadStatus: entry.TrackedDownloadStatus,
	}
}

func (identity QueueIdentity) Entry() queuefinalize.Entry {
	return queuefinalize.Entry{
		QueueID: identity.QueueID, DownloadID: identity.DownloadID,
		SubjectID: identity.SubjectID, Status: identity.Status,
		TrackedDownloadStatus: identity.TrackedDownloadStatus,
	}
}

type Request struct {
	Version   string        `json:"version"`
	RequestID string        `json:"request_id"`
	Service   Service       `json:"service"`
	CaseID    string        `json:"case_id"`
	Action    Action        `json:"action"`
	Queue     QueueIdentity `json:"queue"`
	CreatedAt time.Time     `json:"created_at"`
}

type requestIdentity struct {
	Version   string        `json:"version"`
	Service   Service       `json:"service"`
	CaseID    string        `json:"case_id"`
	Action    Action        `json:"action"`
	Queue     QueueIdentity `json:"queue"`
	CreatedAt time.Time     `json:"created_at"`
}

func NewRequest(
	service Service,
	caseID string,
	queue QueueIdentity,
	createdAt time.Time,
) (Request, error) {
	request := Request{
		Version: RequestVersion, Service: service, CaseID: caseID,
		Action: ActionRemoveTracking, Queue: queue, CreatedAt: createdAt.UTC(),
	}
	request.RequestID = calculateID(request)
	if err := request.Validate(); err != nil {
		return Request{}, err
	}
	return request, nil
}

func (request Request) Validate() error {
	if request.Version != RequestVersion {
		return fmt.Errorf("unsupported queue action request version %q", request.Version)
	}
	if request.Service != ServiceLidarr && request.Service != ServiceRadarr {
		return fmt.Errorf("invalid queue action service %q", request.Service)
	}
	if !fingerprintPattern.MatchString(request.CaseID) {
		return fmt.Errorf("invalid queue action case ID")
	}
	if request.Action != ActionRemoveTracking || !request.Queue.Entry().Eligible() {
		return fmt.Errorf("invalid queue action")
	}
	if request.CreatedAt.IsZero() || request.CreatedAt.Location() != time.UTC {
		return fmt.Errorf("queue action creation time must be UTC")
	}
	if !fingerprintPattern.MatchString(request.RequestID) || request.RequestID != calculateID(request) {
		return fmt.Errorf("queue action request ID does not match its contents")
	}
	return nil
}

func calculateID(request Request) string {
	data, err := json.Marshal(requestIdentity{
		Version: request.Version, Service: request.Service, CaseID: request.CaseID,
		Action: request.Action, Queue: request.Queue, CreatedAt: request.CreatedAt,
	})
	if err != nil {
		panic(err)
	}
	digest := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(digest[:])
}

func digest(fingerprint string) string {
	return strings.TrimPrefix(fingerprint, "sha256:")
}
