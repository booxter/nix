package fileidentity

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
)

const fingerprintDomain = "radarr-repair-file-metadata-v1\x00"

type Snapshot struct {
	Device    uint64
	Inode     uint64
	SizeBytes int64
	MTimeNS   int64
}

// Fingerprint returns a versioned metadata fingerprint without reading file
// contents. Each field is an unsigned 64-bit big-endian word, so signed fields
// retain their two's-complement bit pattern.
func (snapshot Snapshot) Fingerprint() string {
	payload := make([]byte, len(fingerprintDomain)+32)
	copy(payload, fingerprintDomain)
	fields := payload[len(fingerprintDomain):]
	binary.BigEndian.PutUint64(fields[0:8], snapshot.Device)
	binary.BigEndian.PutUint64(fields[8:16], snapshot.Inode)
	binary.BigEndian.PutUint64(fields[16:24], uint64(snapshot.SizeBytes))
	binary.BigEndian.PutUint64(fields[24:32], uint64(snapshot.MTimeNS))

	digest := sha256.Sum256(payload)
	return "sha256:" + hex.EncodeToString(digest[:])
}
