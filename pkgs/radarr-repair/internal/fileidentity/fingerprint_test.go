package fileidentity

import (
	"os"
	"testing"
)

func TestSnapshotFingerprintHasStableEncoding(t *testing.T) {
	t.Parallel()

	snapshot := Snapshot{
		Device:    0x0102030405060708,
		Inode:     0x1112131415161718,
		SizeBytes: 0x2122232425262728,
		MTimeNS:   0x3132333435363738,
	}
	const want = "sha256:0cd0308142123f17781c577fb8ad2abb4d4462d57c7e61cbc90898660d8eb87b"
	if got := snapshot.Fingerprint(); got != want {
		t.Fatalf("fingerprint = %q, want %q", got, want)
	}
}

func TestSnapshotFromFileInfo(t *testing.T) {
	t.Parallel()
	file, err := os.CreateTemp(t.TempDir(), "media")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("audio"); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(file.Name())
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := FromFileInfo(info)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Device == 0 || snapshot.Inode == 0 || snapshot.SizeBytes != 5 ||
		snapshot.MTimeNS == 0 {
		t.Fatalf("snapshot = %#v", snapshot)
	}
}

func TestSnapshotFingerprintIncludesEveryField(t *testing.T) {
	t.Parallel()

	original := Snapshot{Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 4}
	changed := []Snapshot{
		{Device: 9, Inode: 2, SizeBytes: 3, MTimeNS: 4},
		{Device: 1, Inode: 9, SizeBytes: 3, MTimeNS: 4},
		{Device: 1, Inode: 2, SizeBytes: 9, MTimeNS: 4},
		{Device: 1, Inode: 2, SizeBytes: 3, MTimeNS: 9},
	}

	wantDifferentFrom := original.Fingerprint()
	for position, candidate := range changed {
		if got := candidate.Fingerprint(); got == wantDifferentFrom {
			t.Fatalf("changed snapshot %d retained fingerprint %q", position, got)
		}
	}
}
