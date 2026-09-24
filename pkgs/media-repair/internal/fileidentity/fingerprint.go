package fileidentity

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"syscall"
)

const (
	strictFingerprintDomain = "radarr-repair-file-metadata-v1\x00"
	stableFingerprintDomain = "media-repair-file-identity-v1\x00"
)

type Snapshot struct {
	Device    uint64
	Inode     uint64
	SizeBytes int64
	MTimeNS   int64
}

func FromFileInfo(info os.FileInfo) (Snapshot, error) {
	if info == nil {
		return Snapshot{}, fmt.Errorf("filesystem metadata is absent")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return Snapshot{}, fmt.Errorf("unsupported filesystem metadata")
	}
	return Snapshot{
		Device: uint64(stat.Dev), Inode: uint64(stat.Ino),
		SizeBytes: info.Size(), MTimeNS: info.ModTime().UnixNano(),
	}, nil
}

// StrictFingerprint identifies one observed filesystem object. It includes the
// device number so open and verify operations can reject a different mount.
func (snapshot Snapshot) StrictFingerprint() string {
	return fingerprint(
		strictFingerprintDomain,
		snapshot.Device,
		snapshot.Inode,
		uint64(snapshot.SizeBytes),
		uint64(snapshot.MTimeNS),
	)
}

// StableFingerprint identifies the same file across a remount. It deliberately
// excludes the device number, which can change while the underlying file does
// not. It is suitable for persisted planning and workspace identities, not for
// authorizing a live file operation.
func (snapshot Snapshot) StableFingerprint() string {
	return fingerprint(
		stableFingerprintDomain,
		snapshot.Inode,
		uint64(snapshot.SizeBytes),
		uint64(snapshot.MTimeNS),
	)
}

// fingerprint encodes each field as an unsigned 64-bit big-endian word, so
// signed fields retain their two's-complement bit pattern.
func fingerprint(domain string, values ...uint64) string {
	payload := make([]byte, len(domain)+8*len(values))
	copy(payload, domain)
	fields := payload[len(domain):]
	for position, value := range values {
		binary.BigEndian.PutUint64(fields[position*8:(position+1)*8], value)
	}

	digest := sha256.Sum256(payload)
	return "sha256:" + hex.EncodeToString(digest[:])
}
