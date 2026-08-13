package reconcile

import (
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type CredentialReader interface {
	Read(Credential) (string, error)
	ReadRaw(string) (string, error)
}

type SystemdCredentials struct {
	Directory string
}

func (credentials SystemdCredentials) ReadRaw(name string) (string, error) {
	payload, err := os.ReadFile(filepath.Join(credentials.Directory, name))
	if err != nil {
		return "", fmt.Errorf("read credential %q: %w", name, err)
	}
	return strings.TrimSpace(string(payload)), nil
}

func (credentials SystemdCredentials) Read(credential Credential) (string, error) {
	payload, err := credentials.ReadRaw(credential.Name)
	if err != nil {
		return "", err
	}
	switch credential.Format {
	case "raw":
		return payload, nil
	case "xml-element":
		decoder := xml.NewDecoder(strings.NewReader(payload))
		for {
			token, tokenErr := decoder.Token()
			if tokenErr != nil {
				return "", fmt.Errorf("find XML element %q in credential %q: %w", credential.Field, credential.Name, tokenErr)
			}
			start, ok := token.(xml.StartElement)
			if !ok || start.Name.Local != credential.Field {
				continue
			}
			var value string
			if err := decoder.DecodeElement(&value, &start); err != nil {
				return "", fmt.Errorf("decode XML element %q: %w", credential.Field, err)
			}
			return strings.TrimSpace(value), nil
		}
	default:
		return "", fmt.Errorf("unsupported credential format %q", credential.Format)
	}
}
