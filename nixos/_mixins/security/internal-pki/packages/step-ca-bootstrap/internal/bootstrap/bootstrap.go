package bootstrap

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	StateDirectory      string   `json:"stateDirectory"`
	Name                string   `json:"name"`
	URL                 string   `json:"url"`
	DNSNames            []string `json:"dnsNames"`
	Address             string   `json:"address"`
	Provisioner         string   `json:"provisioner"`
	CertificateLifetime string   `json:"certificateLifetime"`
}

func LoadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open bootstrap config: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode bootstrap config: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("decode bootstrap config: trailing JSON value")
	}
	if err := config.validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) validate() error {
	fields := map[string]string{
		"stateDirectory":      config.StateDirectory,
		"name":                config.Name,
		"url":                 config.URL,
		"address":             config.Address,
		"provisioner":         config.Provisioner,
		"certificateLifetime": config.CertificateLifetime,
	}
	for name, value := range fields {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s must not be empty", name)
		}
	}
	if len(config.DNSNames) == 0 {
		return errors.New("dnsNames must not be empty")
	}
	for _, name := range config.DNSNames {
		if strings.TrimSpace(name) == "" {
			return errors.New("dnsNames must not contain empty names")
		}
	}
	if !filepath.IsAbs(config.StateDirectory) {
		return errors.New("stateDirectory must be an absolute path")
	}
	parsedURL, err := url.Parse(config.URL)
	if err != nil || parsedURL.Scheme != "https" || parsedURL.Host == "" {
		return errors.New("url must be an absolute HTTPS URL")
	}
	if _, _, err := net.SplitHostPort(config.Address); err != nil {
		return fmt.Errorf("address must contain a valid host and port: %w", err)
	}
	lifetime, err := time.ParseDuration(config.CertificateLifetime)
	if err != nil || lifetime <= 0 {
		return errors.New("certificateLifetime must be a positive duration")
	}
	return nil
}

func (config Config) caConfigPath() string {
	return filepath.Join(config.StateDirectory, "config", "ca.json")
}

func (config Config) defaultsPath() string {
	return filepath.Join(config.StateDirectory, "config", "defaults.json")
}

func (config Config) passwordPath() string {
	return filepath.Join(config.StateDirectory, "password.txt")
}

func (config Config) provisionerPasswordPath() string {
	return filepath.Join(config.StateDirectory, "provisioner-password.txt")
}

type Initializer interface {
	Initialize(context.Context, Config) error
}

type StepInitializer struct {
	Executable string
	Stdout     io.Writer
	Stderr     io.Writer
}

func (initializer StepInitializer) Initialize(ctx context.Context, config Config) error {
	// Smallstep exposes initialization through the step CLI; its command
	// implementation is not a supported library API.
	arguments := []string{
		"ca", "init",
		"--deployment-type", "standalone",
		"--name", config.Name,
	}
	for _, name := range config.DNSNames {
		arguments = append(arguments, "--dns", name)
	}
	arguments = append(arguments,
		"--address", config.Address,
		"--provisioner", config.Provisioner,
		"--password-file", config.passwordPath(),
		"--provisioner-password-file", config.provisionerPasswordPath(),
		"--acme",
	)
	command := exec.CommandContext(ctx, initializer.Executable, arguments...)
	command.Stdout = initializer.Stdout
	command.Stderr = initializer.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("initialize step-ca: %w", err)
	}
	return nil
}

func Run(ctx context.Context, config Config, initializer Initializer, random io.Reader) error {
	if err := config.validate(); err != nil {
		return err
	}
	initialized, err := nonEmpty(config.caConfigPath())
	if err != nil {
		return err
	}
	if !initialized {
		if err := ensurePassword(config.passwordPath(), random); err != nil {
			return err
		}
		if err := ensurePassword(config.provisionerPasswordPath(), random); err != nil {
			return err
		}
		if err := initializer.Initialize(ctx, config); err != nil {
			return err
		}
	}
	if err := reconcileCAConfig(config); err != nil {
		return err
	}
	return reconcileDefaults(config)
}

func nonEmpty(path string) (bool, error) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", path, err)
	}
	return info.Size() > 0, nil
}

func ensurePassword(path string, random io.Reader) error {
	present, err := nonEmpty(path)
	if err != nil || present {
		return err
	}
	secret := make([]byte, 48)
	defer clear(secret)
	if _, err := io.ReadFull(random, secret); err != nil {
		return fmt.Errorf("generate password: %w", err)
	}
	encoded := base64.StdEncoding.AppendEncode(nil, secret)
	defer clear(encoded)
	encoded = append(encoded, '\n')
	return writeAtomic(path, 0o600, func(file io.Writer) error {
		_, err := file.Write(encoded)
		return err
	})
}

func reconcileCAConfig(config Config) error {
	contents, err := readObject(config.caConfigPath())
	if err != nil {
		return err
	}
	contents["dnsNames"] = config.DNSNames

	authority, ok := contents["authority"].(map[string]any)
	if !ok {
		return errors.New("ca.json authority is not an object")
	}
	provisioners, ok := authority["provisioners"].([]any)
	if !ok {
		return errors.New("ca.json authority.provisioners is not an array")
	}
	found := false
	for _, rawProvisioner := range provisioners {
		provisioner, ok := rawProvisioner.(map[string]any)
		if !ok || provisioner["name"] != config.Provisioner {
			continue
		}
		claims, ok := provisioner["claims"].(map[string]any)
		if !ok {
			claims = make(map[string]any)
			provisioner["claims"] = claims
		}
		claims["defaultTLSCertDuration"] = config.CertificateLifetime
		claims["maxTLSCertDuration"] = config.CertificateLifetime
		found = true
	}
	if !found {
		return fmt.Errorf("provisioner %q is missing from ca.json", config.Provisioner)
	}
	return writeJSONAtomic(config.caConfigPath(), contents)
}

func reconcileDefaults(config Config) error {
	contents, err := readObject(config.defaultsPath())
	if err != nil {
		return err
	}
	contents["ca-url"] = config.URL
	return writeJSONAtomic(config.defaultsPath(), contents)
}

func readObject(path string) (map[string]any, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var object map[string]any
	if err := json.Unmarshal(contents, &object); err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	if object == nil {
		return nil, fmt.Errorf("%s is not a JSON object", path)
	}
	return object, nil
}

func writeJSONAtomic(path string, value any) error {
	return writeAtomic(path, 0o600, func(file io.Writer) error {
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		return encoder.Encode(value)
	})
}

func writeAtomic(path string, mode os.FileMode, write func(io.Writer) error) (result error) {
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("create temporary file for %s: %w", path, err)
	}
	temporaryPath := temporary.Name()
	defer func() {
		if result != nil {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set mode for %s: %w", path, err)
	}
	if err := write(temporary); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync %s: %w", path, err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close %s: %w", path, err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install %s: %w", path, err)
	}
	dir, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("open directory %s: %w", directory, err)
	}
	defer dir.Close()
	if err := dir.Sync(); err != nil {
		return fmt.Errorf("sync directory %s: %w", directory, err)
	}
	return nil
}
