package xpost

import "context"

// Request defines the message payload shared across all providers.
type Request struct {
	Message   string
	ImagePath string
	ImageAlt  string
	Link      string // Optional URL to append to message with proper formatting
}

// Poster abstracts a social network that can publish content.
type Poster interface {
	Name() string
	// Validate checks if the request meets platform constraints (character limits, etc.)
	// without posting. Returns nil if valid.
	Validate(req Request) error
	Post(ctx context.Context, req Request) error
}
