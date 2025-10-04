package logutil

import (
	"os"
	"sync"

	"github.com/charmbracelet/log"
)

var (
	logger  = log.NewWithOptions(os.Stderr, log.Options{Prefix: "xpost", ReportTimestamp: true, Level: log.InfoLevel})
	verbose bool
	mu      sync.RWMutex
)

// SetVerbose adjusts the global logging level.
func SetVerbose(enable bool) {
	mu.Lock()
	defer mu.Unlock()
	verbose = enable
	if enable {
		logger.SetLevel(log.DebugLevel)
	} else {
		logger.SetLevel(log.InfoLevel)
	}
}

// Verbose reports whether verbose logging is enabled.
func Verbose() bool {
	mu.RLock()
	defer mu.RUnlock()
	return verbose
}

// Debugf logs a debug message when verbose logging is enabled.
func Debugf(format string, args ...any) {
	logger.Debugf(format, args...)
}

// Infof logs an informational message.
func Infof(format string, args ...any) {
	logger.Infof(format, args...)
}

// Errorf logs an error message.
func Errorf(format string, args ...any) {
	logger.Errorf(format, args...)
}
