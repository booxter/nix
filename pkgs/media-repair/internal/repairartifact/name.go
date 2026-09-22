package repairartifact

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

const (
	publishedNameDomain = "radarr-repair-worker-published-name-v1\x00"
	publishedNamePrefix = "radarr-repair-"
)

func PublishedName(artifactID string, extension string) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte(publishedNameDomain))
	_, _ = digest.Write([]byte(artifactID))
	return publishedNamePrefix + hex.EncodeToString(digest.Sum(nil)) + extension
}

func IsPublishedName(name string) bool {
	if strings.ContainsAny(name, "/\\") {
		return false
	}
	for _, extension := range []string{".avi", ".mkv", ".mp4"} {
		stem, found := strings.CutSuffix(name, extension)
		if !found {
			continue
		}
		digest, found := strings.CutPrefix(stem, publishedNamePrefix)
		if !found || len(digest) != sha256.Size*2 {
			return false
		}
		for _, character := range digest {
			if !(character >= '0' && character <= '9') &&
				!(character >= 'a' && character <= 'f') {
				return false
			}
		}
		return true
	}
	return false
}
