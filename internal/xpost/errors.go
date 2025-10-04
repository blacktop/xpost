package xpost

import (
	"fmt"
	"strings"
)

// MissingEnvError is returned when required configuration is missing.
type MissingEnvError struct {
	Provider  string
	Variables []string
}

func (e MissingEnvError) Error() string {
	if len(e.Variables) == 0 {
		return fmt.Sprintf("%s credentials not configured", e.Provider)
	}
	return fmt.Sprintf("%s credentials not configured (missing %s)", e.Provider, strings.Join(e.Variables, ", "))
}

// ValidationError captures provider-specific validation issues.
type ValidationError struct {
	Provider string
	Reason   string
}

func (e ValidationError) Error() string {
	return fmt.Sprintf("%s validation failed: %s", e.Provider, e.Reason)
}
