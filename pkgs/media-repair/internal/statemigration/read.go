// Package statemigration is the one-time converter for the deployed JSON state.
// It is removed after the cutover; the daemon does not read old state formats.
package statemigration

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func readJSON[T any](path string) (T, bool, error) {
	var value T
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return value, false, nil
	}
	if err != nil {
		return value, false, err
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return value, false, fmt.Errorf("decode %s: %w", path, err)
	}
	return value, true, nil
}

func readDirectory[T any](directory string) ([]T, error) {
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var records []T
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		record, _, err := readJSON[T](filepath.Join(directory, entry.Name()))
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, nil
}

func recordPath(directory, id string) string {
	return filepath.Join(directory, strings.TrimPrefix(id, "sha256:")+".json")
}
