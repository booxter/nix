//go:build linux

package bridgeaccess

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigValidatesTheGeneratedBoundary(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	tests := []struct {
		name      string
		contents  string
		wantError bool
	}{
		{
			name:     "valid",
			contents: `{"namespace":"wg","sourceAddress":"192.168.50.5","tcpPorts":[443,8080]}`,
		},
		{
			name:      "unknown field",
			contents:  `{"namespace":"wg","sourceAddress":"192.168.50.5","tcpPorts":[443],"extra":true}`,
			wantError: true,
		},
		{
			name:      "IPv6 source",
			contents:  `{"namespace":"wg","sourceAddress":"fd00::1","tcpPorts":[443]}`,
			wantError: true,
		},
		{
			name:      "duplicate port",
			contents:  `{"namespace":"wg","sourceAddress":"192.168.50.5","tcpPorts":[443,443]}`,
			wantError: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(test.contents), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := LoadConfig(path)
			if (err != nil) != test.wantError {
				t.Fatalf("LoadConfig error = %v, wantError=%v", err, test.wantError)
			}
		})
	}
}
