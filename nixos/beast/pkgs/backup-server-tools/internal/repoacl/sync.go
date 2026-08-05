package repoacl

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const markerName = ".offload-acl-initialized"

type Granter interface {
	GrantAccess(user string, paths []string) error
	GrantDefault(user string, directories []string) error
}

func Sync(config Config, granter Granter) error {
	repositoryInfo, err := os.Stat(config.Repository)
	if errors.Is(err, os.ErrNotExist) || (err == nil && !repositoryInfo.IsDir()) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect repository: %w", err)
	}
	if err := granter.GrantAccess(config.User, []string{config.Repository}); err != nil {
		return err
	}
	if err := granter.GrantDefault(config.User, []string{config.Repository}); err != nil {
		return err
	}

	configPath := filepath.Join(config.Repository, "config")
	configInfo, err := os.Stat(configPath)
	if errors.Is(err, os.ErrNotExist) || (err == nil && !configInfo.Mode().IsRegular()) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect restic configuration: %w", err)
	}

	marker := filepath.Join(config.Repository, markerName)
	markerInfo, err := os.Stat(marker)
	fullScan := errors.Is(err, os.ErrNotExist)
	if err != nil && !fullScan {
		return fmt.Errorf("inspect ACL marker: %w", err)
	}
	if !fullScan {
		fullScan = configInfo.ModTime().After(markerInfo.ModTime())
	}

	var cutoff time.Time
	if !fullScan {
		cutoff = markerInfo.ModTime()
	}
	paths, directories, err := changedPaths(config.Repository, cutoff)
	if err != nil {
		return err
	}
	if err := granter.GrantAccess(config.User, paths); err != nil {
		return err
	}
	if err := granter.GrantDefault(config.User, directories); err != nil {
		return err
	}
	if err := touch(marker); err != nil {
		return fmt.Errorf("update ACL marker: %w", err)
	}
	return nil
}

func changedPaths(root string, cutoff time.Time) ([]string, []string, error) {
	var paths []string
	var directories []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !cutoff.IsZero() && !info.ModTime().After(cutoff) {
			return nil
		}
		paths = append(paths, path)
		if entry.IsDir() {
			directories = append(directories, path)
		}
		return nil
	})
	if err != nil {
		return nil, nil, fmt.Errorf("scan repository ACL candidates: %w", err)
	}
	return paths, directories, nil
}

func touch(path string) error {
	now := time.Now()
	if err := os.Chtimes(path, now, now); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	return file.Close()
}
