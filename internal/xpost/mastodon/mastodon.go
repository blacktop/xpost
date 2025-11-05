package mastodon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/blacktop/xpost/internal/xpost"
	mastodonapi "github.com/mattn/go-mastodon"
)

const (
	envServer       = "XPOST_MASTODON_SERVER"
	envAccessToken  = "XPOST_MASTODON_ACCESS_TOKEN"
	envClientID     = "XPOST_MASTODON_CLIENT_ID"
	envClientSecret = "XPOST_MASTODON_CLIENT_SECRET"

	providerName   = "mastodon"
	requestTimeout = 30 * time.Second
)

// Config contains the settings needed to reach a Mastodon server.
type Config struct {
	Server       string
	AccessToken  string
	ClientID     string
	ClientSecret string
}

// Client wraps the Mastodon API client with xpost semantics.
type Client struct {
	client *mastodonapi.Client
}

// New constructs a Mastodon poster based on environment configuration.
func New(ctx context.Context) (xpost.Poster, error) {
	cfg, err := loadConfigFromEnv()
	if err != nil {
		return nil, err
	}

	mastodonClient := mastodonapi.NewClient(&mastodonapi.Config{
		Server:       cfg.Server,
		AccessToken:  cfg.AccessToken,
		ClientID:     cfg.ClientID,
		ClientSecret: cfg.ClientSecret,
	})
	mastodonClient.Timeout = requestTimeout

	return &Client{client: mastodonClient}, nil
}

// Name identifies the provider.
func (c *Client) Name() string { return providerName }

// Post publishes a new toot to the configured Mastodon instance.
func (c *Client) Post(ctx context.Context, req xpost.Request) error {
	var mediaIDs []mastodonapi.ID
	if req.ImagePath != "" {
		attachment, err := c.uploadMedia(ctx, req.ImagePath, req.ImageAlt)
		if err != nil {
			return err
		}
		mediaIDs = append(mediaIDs, attachment.ID)
	}

	// Build status text with link if provided
	status := req.Message
	if req.Link != "" {
		status = status + "\n\n" + req.Link
	}

	_, err := c.client.PostStatus(ctx, &mastodonapi.Toot{
		Status:   status,
		MediaIDs: mediaIDs,
	})
	if err != nil {
		return fmt.Errorf("post status: %w", err)
	}

	return nil
}

func (c *Client) uploadMedia(ctx context.Context, path, alt string) (*mastodonapi.Attachment, error) {
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, xpost.ValidationError{Provider: providerName, Reason: fmt.Sprintf("image %q not found", path)}
		}
		return nil, fmt.Errorf("open image: %w", err)
	}
	defer file.Close()

	attachment, err := c.client.UploadMediaFromMedia(ctx, &mastodonapi.Media{
		File:        file,
		Description: alt,
	})
	if err != nil {
		return nil, fmt.Errorf("upload media: %w", err)
	}

	return attachment, nil
}

func loadConfigFromEnv() (Config, error) {
	cfg := Config{
		Server:       strings.TrimSpace(os.Getenv(envServer)),
		AccessToken:  strings.TrimSpace(os.Getenv(envAccessToken)),
		ClientID:     strings.TrimSpace(os.Getenv(envClientID)),
		ClientSecret: strings.TrimSpace(os.Getenv(envClientSecret)),
	}

	var missing []string
	if cfg.Server == "" {
		missing = append(missing, envServer)
	}
	if cfg.AccessToken == "" {
		missing = append(missing, envAccessToken)
	}

	if len(missing) > 0 {
		return Config{}, xpost.MissingEnvError{Provider: providerName, Variables: missing}
	}

	return cfg, nil
}
