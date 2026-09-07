package mediaroot

import (
	"fmt"
	"path/filepath"
	"strings"
)

type Mappings map[string]string

func NewMappings() Mappings {
	return make(Mappings)
}

func (mappings Mappings) String() string {
	return fmt.Sprintf("%d configured", len(mappings))
}

func (mappings Mappings) Set(value string) error {
	rootID, rootPath, found := strings.Cut(value, "=")
	if !found || rootID == "" || rootPath == "" {
		return fmt.Errorf("media root must have the form ID=PATH")
	}
	if strings.ContainsRune(rootID, '\x00') {
		return fmt.Errorf("media root ID contains a null byte")
	}
	if strings.ContainsRune(rootPath, '\x00') || !filepath.IsAbs(rootPath) ||
		filepath.Clean(rootPath) != rootPath {
		return fmt.Errorf("media root %q must have an absolute clean path", rootID)
	}
	if _, exists := mappings[rootID]; exists {
		return fmt.Errorf("media root %q is configured more than once", rootID)
	}
	mappings[rootID] = rootPath
	return nil
}

func (mappings Mappings) Paths() map[string]string {
	paths := make(map[string]string, len(mappings))
	for rootID, rootPath := range mappings {
		paths[rootID] = rootPath
	}
	return paths
}
