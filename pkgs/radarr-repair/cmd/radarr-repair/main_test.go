package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "contracts", "v2", "examples", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestValidateCaseFromStandardInput(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := run(
		[]string{"validate-case", "-"},
		bytes.NewReader(fixture(t, "repair-case-joinable.json")),
		&stdout,
		&stderr,
	)
	if err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "valid repair case\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestValidateDecisionFromFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "decision.json")
	if err := os.WriteFile(path, fixture(t, "repair-decision-join.json"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := run(
		[]string{"validate-decision", path},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "valid repair decision: join_parts_v1\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestValidationFailureDoesNotEchoInput(t *testing.T) {
	const secret = "do-not-echo-this"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := run(
		[]string{"validate-case", "-"},
		strings.NewReader(`{"unexpected":"`+secret+`"}`),
		&stdout,
		&stderr,
	)
	if err == nil {
		t.Fatal("invalid case was accepted")
	}
	if stdout.Len() != 0 || strings.Contains(stderr.String(), secret) || strings.Contains(err.Error(), secret) {
		t.Fatalf("input was echoed: stdout=%q stderr=%q error=%q", stdout.String(), stderr.String(), err)
	}
}

func TestUsageAndUnknownCommand(t *testing.T) {
	tests := [][]string{
		nil,
		{"unknown"},
		{"validate-case"},
		{"validate-decision", "one", "two"},
	}
	for _, arguments := range tests {
		var stderr bytes.Buffer
		if err := run(arguments, strings.NewReader(""), &bytes.Buffer{}, &stderr); err == nil {
			t.Fatalf("arguments %q were accepted", arguments)
		}
		if stderr.Len() == 0 {
			t.Fatalf("arguments %q produced no usage", arguments)
		}
	}
}

func TestOversizedInputIsRejected(t *testing.T) {
	var stdout bytes.Buffer
	err := run(
		[]string{"validate-case", "-"},
		strings.NewReader(strings.Repeat("x", maximumDocumentSize+1)),
		&stdout,
		&bytes.Buffer{},
	)
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("error = %v", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q", stdout.String())
	}
}
