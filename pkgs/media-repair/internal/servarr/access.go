package servarr

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"
)

const MaximumAPIKeySize = 4 << 10

func ValidateLoopbackHTTP(service, endpoint string) error {
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("%s URL is invalid", service)
	}
	if parsed.Scheme != "http" || parsed.Host == "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" || !isLoopbackHost(parsed.Hostname()) {
		return fmt.Errorf(
			"%s URL must use loopback HTTP without credentials, query, or fragment",
			service,
		)
	}
	return nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(strings.TrimSuffix(host, "."), "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

func ReadAPIKey(service, path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %s API-key file: %w", service, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("inspect %s API-key file: %w", service, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%s API-key file is not a regular file", service)
	}
	data, err := io.ReadAll(io.LimitReader(file, MaximumAPIKeySize+1))
	if err != nil {
		return "", fmt.Errorf("read %s API-key file: %w", service, err)
	}
	if len(data) > MaximumAPIKeySize {
		return "", fmt.Errorf("%s API-key file exceeds %d bytes", service, MaximumAPIKeySize)
	}
	key := string(data)
	if strings.HasSuffix(key, "\n") {
		key = strings.TrimSuffix(key, "\n")
		key = strings.TrimSuffix(key, "\r")
	}
	if key == "" || !utf8.ValidString(key) || strings.TrimSpace(key) != key {
		return "", fmt.Errorf("%s API-key file contains an invalid credential", service)
	}
	for _, character := range key {
		if unicode.IsControl(character) {
			return "", fmt.Errorf("%s API-key file contains an invalid credential", service)
		}
	}
	return key, nil
}

func DirectHTTPTransport() (*http.Transport, error) {
	base, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return nil, fmt.Errorf("default HTTP transport has an unexpected type")
	}
	transport := base.Clone()
	transport.Proxy = nil
	return transport, nil
}
