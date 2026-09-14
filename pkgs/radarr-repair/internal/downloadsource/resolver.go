package downloadsource

import (
	"context"
	"fmt"
	"strings"
	"unicode"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

type Registration struct {
	Protocol   controller.DownloadProtocol
	ClientName string
	Reader     controller.DownloadReader
}

type sourceKey struct {
	protocol   controller.DownloadProtocol
	clientName string
}

type Resolver struct {
	readers map[sourceKey]controller.DownloadReader
}

var _ controller.DownloadResolver = (*Resolver)(nil)

func New(registrations ...Registration) (*Resolver, error) {
	readers := make(map[sourceKey]controller.DownloadReader, len(registrations))
	for _, registration := range registrations {
		if !validName(string(registration.Protocol)) {
			return nil, fmt.Errorf("download source protocol is invalid")
		}
		if !validName(registration.ClientName) {
			return nil, fmt.Errorf("download source client name is invalid")
		}
		if registration.Reader == nil {
			return nil, fmt.Errorf("download source reader is required")
		}
		key := sourceKey{
			protocol: registration.Protocol, clientName: registration.ClientName,
		}
		if _, exists := readers[key]; exists {
			return nil, fmt.Errorf(
				"download source %q and %q is registered more than once",
				registration.Protocol,
				registration.ClientName,
			)
		}
		readers[key] = registration.Reader
	}
	if len(readers) == 0 {
		return nil, fmt.Errorf("at least one download source is required")
	}
	return &Resolver{readers: readers}, nil
}

func (resolver *Resolver) Supports(
	protocol controller.DownloadProtocol,
	clientName string,
) bool {
	if resolver == nil {
		return false
	}
	_, exists := resolver.readers[sourceKey{protocol: protocol, clientName: clientName}]
	return exists
}

func (resolver *Resolver) Resolve(
	ctx context.Context,
	record controller.RadarrQueueRecord,
) (controller.Download, bool, error) {
	if resolver == nil {
		return controller.Download{}, false, fmt.Errorf("download resolver is not configured")
	}
	reader, exists := resolver.readers[sourceKey{
		protocol: record.Protocol, clientName: record.DownloadClient,
	}]
	if !exists {
		return controller.Download{}, false, fmt.Errorf(
			"download source %q and %q is not configured",
			record.Protocol,
			record.DownloadClient,
		)
	}
	return reader.FindDownload(ctx, record.DownloadID)
}

func validName(value string) bool {
	if value == "" || strings.TrimSpace(value) != value {
		return false
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}
