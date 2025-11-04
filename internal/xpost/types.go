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
	Post(ctx context.Context, req Request) error
}
