package materialize

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/worker/mediaevidence"
)

func (executor *Executor) extractAndProbe(
	ctx context.Context,
	archive *os.File,
	workspacePath string,
	workspaceComponents []string,
	groupID int,
	extensions map[string]struct{},
	mediaName string,
) ([]Artifact, error) {
	reader := tar.NewReader(archive)
	entries := 0
	var totalBytes int64
	seen := make(map[string]struct{})
	artifacts := make([]Artifact, 0)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read tar: %w", err)
		}
		entries++
		if entries > maximumEntries {
			return nil, fmt.Errorf("archive contains too many entries")
		}
		name, err := safeArchiveName(header.Name, header.Typeflag == tar.TypeDir)
		if err != nil {
			return nil, err
		}
		if _, duplicate := seen[name]; duplicate {
			return nil, fmt.Errorf("archive repeats path %q", name)
		}
		seen[name] = struct{}{}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := ensureWorkspaceDirectory(
				filepath.Join(workspacePath, filepath.FromSlash(name)),
				groupID,
			); err != nil {
				return nil, err
			}
		case tar.TypeReg, tar.TypeRegA:
			if header.Size < 0 || header.Size > maximumFileBytes || totalBytes > maximumTotalBytes-header.Size {
				return nil, fmt.Errorf("archive expansion exceeds limits")
			}
			totalBytes += header.Size
			artifact, audio, err := extractFile(
				reader, workspacePath, workspaceComponents, name, header.Size, groupID,
				extensions,
			)
			if err != nil {
				return nil, err
			}
			if !audio {
				continue
			}
			evidence, err := executor.prober.Probe(
				ctx, filepath.Join(workspacePath, filepath.FromSlash(name)),
			)
			if err != nil {
				return nil, fmt.Errorf("probe extracted %s: %w", mediaName, err)
			}
			artifact.Evidence = mediaevidence.FromProbe(evidence)
			artifacts = append(artifacts, artifact)
		default:
			return nil, fmt.Errorf("archive entry %q is not a regular file or directory", name)
		}
	}
	if len(artifacts) == 0 {
		return nil, fmt.Errorf("archive contains no supported %s", mediaName)
	}
	sort.Slice(artifacts, func(left, right int) bool {
		return artifacts[left].RelativePath < artifacts[right].RelativePath
	})
	return artifacts, nil
}

func extractFile(
	reader io.Reader,
	workspacePath string,
	workspaceComponents []string,
	name string,
	size int64,
	groupID int,
	extensions map[string]struct{},
) (Artifact, bool, error) {
	destination := filepath.Join(workspacePath, filepath.FromSlash(name))
	if err := ensureWorkspaceDirectory(filepath.Dir(destination), groupID); err != nil {
		return Artifact{}, false, err
	}
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640)
	if err != nil {
		return Artifact{}, false, err
	}
	hash := sha256.New()
	written, copyErr := io.CopyN(io.MultiWriter(output, hash), reader, size)
	closeErr := output.Close()
	if copyErr != nil || closeErr != nil || written != size {
		return Artifact{}, false, errors.Join(copyErr, closeErr, fmt.Errorf("short archive member"))
	}
	if err := os.Chmod(destination, 0o640); err != nil {
		return Artifact{}, false, err
	}
	if err := os.Chown(destination, -1, groupID); err != nil {
		return Artifact{}, false, err
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	fingerprint := "sha256:" + digest
	components := append(append([]string(nil), workspaceComponents...), strings.Split(name, "/")...)
	_, audio := extensions[strings.ToLower(path.Ext(name))]
	return Artifact{
		ArtifactID: ArtifactID(name, fingerprint), PathComponents: components,
		RelativePath: name, SizeBytes: size, Fingerprint: fingerprint,
	}, audio, nil
}
