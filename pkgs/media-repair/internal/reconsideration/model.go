package reconsideration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
)

const (
	RequestVersion     = "media-repair-reconsideration/v1"
	MaximumGuidanceLen = 2_000
)

type Service string

const (
	ServiceLidarr Service = "lidarr"
	ServiceRadarr Service = "radarr"
)

var fingerprintPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type Request struct {
	Version   string    `json:"version"`
	RequestID string    `json:"request_id"`
	Service   Service   `json:"service"`
	CaseID    string    `json:"case_id"`
	Guidance  string    `json:"guidance"`
	CreatedAt time.Time `json:"created_at"`
}

type requestIdentity struct {
	Version   string    `json:"version"`
	Service   Service   `json:"service"`
	CaseID    string    `json:"case_id"`
	Guidance  string    `json:"guidance"`
	CreatedAt time.Time `json:"created_at"`
}

func NewRequest(service Service, caseID, guidance string, createdAt time.Time) (Request, error) {
	request := Request{
		Version: RequestVersion, Service: service, CaseID: caseID,
		Guidance: guidance, CreatedAt: createdAt.UTC(),
	}
	request.RequestID = calculateID(request)
	if err := request.Validate(); err != nil {
		return Request{}, err
	}
	return request, nil
}

func (request Request) Validate() error {
	if request.Version != RequestVersion {
		return fmt.Errorf("unsupported reconsideration request version %q", request.Version)
	}
	if request.Service != ServiceLidarr && request.Service != ServiceRadarr {
		return fmt.Errorf("invalid reconsideration service %q", request.Service)
	}
	if !fingerprintPattern.MatchString(request.CaseID) {
		return fmt.Errorf("invalid reconsideration case ID")
	}
	if request.Guidance == "" || request.Guidance != strings.TrimSpace(request.Guidance) ||
		len(request.Guidance) > MaximumGuidanceLen {
		return fmt.Errorf("reconsideration guidance is invalid")
	}
	for _, character := range request.Guidance {
		if unicode.IsControl(character) && character != '\n' && character != '\t' {
			return fmt.Errorf("reconsideration guidance contains control characters")
		}
	}
	if request.CreatedAt.IsZero() || request.CreatedAt.Location() != time.UTC {
		return fmt.Errorf("reconsideration creation time must be UTC")
	}
	if !fingerprintPattern.MatchString(request.RequestID) ||
		request.RequestID != calculateID(request) {
		return fmt.Errorf("reconsideration request ID does not match its contents")
	}
	return nil
}

func calculateID(request Request) string {
	data, err := json.Marshal(requestIdentity{
		Version: request.Version, Service: request.Service, CaseID: request.CaseID,
		Guidance: request.Guidance, CreatedAt: request.CreatedAt,
	})
	if err != nil {
		panic(err)
	}
	digest := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(digest[:])
}
