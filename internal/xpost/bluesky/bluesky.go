package bluesky

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/blacktop/xpost/internal/xpost"
	"github.com/bluesky-social/indigo/api/atproto"
	"github.com/bluesky-social/indigo/api/bsky"
	"github.com/bluesky-social/indigo/lex/util"
	"github.com/bluesky-social/indigo/xrpc"
)

const (
	envHandle      = "XPOST_BLUESKY_HANDLE"
	envAppPassword = "XPOST_BLUESKY_APP_PASSWORD"
	envPDSURL      = "XPOST_BLUESKY_PDS_URL"

	providerName   = "bluesky"
	requestTimeout = 30 * time.Second
)

// Config allows the caller to supply defaults prior to reading environment variables.
type Config struct {
	PDSURL string
}

// Client implements the xpost.Poster interface for Bluesky.
type Client struct {
	client *xrpc.Client
}

// New constructs a Bluesky poster.
func New(ctx context.Context, base Config) (xpost.Poster, error) {
	cfg, err := loadConfig(base)
	if err != nil {
		return nil, err
	}

	httpClient := &http.Client{Timeout: requestTimeout}
	userAgent := "xpost/1"
	xrpcClient := &xrpc.Client{
		Client:    httpClient,
		Host:      cfg.PDSURL,
		UserAgent: &userAgent,
	}

	session, err := atproto.ServerCreateSession(ctx, xrpcClient, &atproto.ServerCreateSession_Input{
		Identifier: cfg.Handle,
		Password:   cfg.AppPassword,
	})
	if err != nil {
		return nil, fmt.Errorf("login: %w", err)
	}

	xrpcClient.Auth = &xrpc.AuthInfo{
		AccessJwt:  session.AccessJwt,
		RefreshJwt: session.RefreshJwt,
		Handle:     session.Handle,
		Did:        session.Did,
	}

	return &Client{client: xrpcClient}, nil
}

// Name identifies the provider.
func (c *Client) Name() string { return providerName }

// Post creates a new Bluesky post with an optional image embed.
func (c *Client) Post(ctx context.Context, req xpost.Request) error {
	post := &bsky.FeedPost{
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		Text:      req.Message,
	}

	if req.ImagePath != "" {
		blob, err := c.uploadImage(ctx, req.ImagePath)
		if err != nil {
			return err
		}
		post.Embed = &bsky.FeedPost_Embed{
			EmbedImages: &bsky.EmbedImages{
				Images: []*bsky.EmbedImages_Image{
					{
						Alt:   req.ImageAlt,
						Image: blob,
					},
				},
			},
		}
	}

	_, err := atproto.RepoCreateRecord(ctx, c.client, &atproto.RepoCreateRecord_Input{
		Collection: "app.bsky.feed.post",
		Repo:       c.client.Auth.Did,
		Record: &util.LexiconTypeDecoder{
			Val: post,
		},
	})
	if err != nil {
		return fmt.Errorf("create record: %w", err)
	}

	return nil
}

func (c *Client) uploadImage(ctx context.Context, path string) (*util.LexBlob, error) {
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, xpost.ValidationError{Provider: providerName, Reason: fmt.Sprintf("image %q not found", path)}
		}
		return nil, fmt.Errorf("open image: %w", err)
	}
	defer file.Close()

	buf := &bytes.Buffer{}
	if _, err := io.Copy(buf, file); err != nil {
		return nil, fmt.Errorf("read image: %w", err)
	}

	resp, err := atproto.RepoUploadBlob(ctx, c.client, bytes.NewReader(buf.Bytes()))
	if err != nil {
		return nil, fmt.Errorf("upload blob: %w", err)
	}

	if resp.Blob == nil {
		return nil, fmt.Errorf("upload blob: empty response")
	}

	return resp.Blob, nil
}

// ProviderConfig merges defaults with environment-defined values.
type ProviderConfig struct {
	Handle      string
	AppPassword string
	PDSURL      string
}

func loadConfig(base Config) (ProviderConfig, error) {
	cfg := ProviderConfig{
		Handle:      strings.TrimSpace(os.Getenv(envHandle)),
		AppPassword: strings.TrimSpace(os.Getenv(envAppPassword)),
		PDSURL:      strings.TrimSpace(os.Getenv(envPDSURL)),
	}

	if cfg.PDSURL == "" {
		cfg.PDSURL = strings.TrimSpace(base.PDSURL)
	}
	if cfg.PDSURL == "" {
		cfg.PDSURL = "https://bsky.social"
	}

	var missing []string
	if cfg.Handle == "" {
		missing = append(missing, envHandle)
	}
	if cfg.AppPassword == "" {
		missing = append(missing, envAppPassword)
	}
	if cfg.PDSURL == "" {
		missing = append(missing, envPDSURL)
	}

	if len(missing) > 0 {
		return ProviderConfig{}, xpost.MissingEnvError{Provider: providerName, Variables: missing}
	}

	return cfg, nil
}
