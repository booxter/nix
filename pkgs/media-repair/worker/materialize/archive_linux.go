package materialize

import (
	"context"
	"fmt"
	"os"
	"path"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
)

func (executor *Executor) Execute(ctx context.Context, request Request) Response {
	switch request.Operation {
	case OperationMaterializeTar, OperationMaterializeTarVideo:
		return executor.materializeArchive(ctx, request)
	default:
		return request.fail("invalid_operation")
	}
}

func (executor *Executor) ExecuteRAR(ctx context.Context, request Request) Response {
	if executor.rar == nil {
		return request.fail("rar_unavailable")
	}
	switch request.Operation {
	case OperationMaterializeRAR, OperationMaterializeRARVideo:
		return executor.materializeArchive(ctx, request)
	default:
		return request.fail("invalid_operation")
	}
}

func (executor *Executor) materializeArchive(ctx context.Context, request Request) Response {
	if err := ctx.Err(); err != nil {
		return request.fail("timeout")
	}
	archive, err := executor.files.Open(
		request.RootID, request.SourceComponents, request.ExpectedFingerprint,
	)
	if err != nil {
		return request.fail(reasonForError(err))
	}
	defer archive.Close()
	archiveInfo, err := archive.Stat()
	if err != nil {
		return request.fail(reasonForError(err))
	}
	archiveSnapshot, err := fileidentity.FromFileInfo(archiveInfo)
	if err != nil {
		return request.fail(reasonForError(err))
	}
	sourceFingerprint := archiveSnapshot.StableFingerprint()
	rootPath, err := executor.files.Path(request.RootID)
	if err != nil {
		return request.fail(reasonForError(err))
	}

	w, cached, err := openWorkspace(rootPath, request, sourceFingerprint)
	if err != nil {
		return request.fail("workspace_error")
	}
	if cached != nil {
		if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
			return request.fail(reasonForError(err))
		}
		return Response{Status: "ok", Success: cached}
	}

	extensions, mediaName := audioExtensions, "audio"
	if request.Operation == OperationMaterializeRARVideo || request.Operation == OperationMaterializeTarVideo {
		extensions, mediaName = videoExtensions, "video"
	}
	var artifacts []Artifact
	switch request.Operation {
	case OperationMaterializeRAR, OperationMaterializeRARVideo:
		artifacts, err = executor.extractRAR(ctx, archive, w, extensions, mediaName)
	default:
		artifacts, err = executor.extractAndProbe(ctx, archive, w.partial, w.components, w.group, extensions, mediaName)
	}
	if err != nil {
		_ = os.RemoveAll(w.partial)
		return request.fail(reasonForError(err))
	}
	if err := executor.files.Verify(archive, request.ExpectedFingerprint); err != nil {
		_ = os.RemoveAll(w.partial)
		return request.fail(reasonForError(err))
	}
	return w.publish(request, sourceFingerprint, artifacts)
}

func safeArchiveName(name string, directory bool) (string, error) {
	if directory {
		name = strings.TrimSuffix(name, "/")
	}
	if name == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("archive path is unsafe")
	}
	clean := path.Clean(name)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || clean != name {
		return "", fmt.Errorf("archive path %q is unsafe", name)
	}
	for _, component := range strings.Split(clean, "/") {
		if component == "" || component == "." || component == ".." || len(component) > 255 {
			return "", fmt.Errorf("archive path %q is unsafe", name)
		}
	}
	return clean, nil
}
