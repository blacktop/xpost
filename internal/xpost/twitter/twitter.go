package twitter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/blacktop/xpost/internal/xpost"
	twitterapi "github.com/dghubble/go-twitter/twitter"
	"github.com/dghubble/oauth1"
)

const (
	envConsumerKey       = "XPOST_TWITTER_CONSUMER_KEY"
	envConsumerSecret    = "XPOST_TWITTER_CONSUMER_SECRET"
	envAccessToken       = "XPOST_TWITTER_ACCESS_TOKEN"
	envAccessTokenSecret = "XPOST_TWITTER_ACCESS_TOKEN_SECRET"

	mediaUploadURL   = "https://upload.twitter.com/1.1/media/upload.json"
	mediaMetadataURL = "https://upload.twitter.com/1.1/media/metadata/create.json"
	requestTimeout   = 30 * time.Second
	providerName     = "twitter"
)

// Config holds the credentials required to authenticate with Twitter.
type Config struct {
	ConsumerKey    string
	ConsumerSecret string
	AccessToken    string
	AccessSecret   string
}

// Client implements the xpost.Poster interface for Twitter/X.
type Client struct {
	httpClient    *http.Client
	twitterClient *twitterapi.Client
}

// New constructs a Twitter poster using credentials from the environment.
func New(ctx context.Context) (xpost.Poster, error) {
	cfg, err := loadConfigFromEnv()
	if err != nil {
		return nil, err
	}

	oauthConfig := oauth1.NewConfig(cfg.ConsumerKey, cfg.ConsumerSecret)
	token := oauth1.NewToken(cfg.AccessToken, cfg.AccessSecret)
	httpClient := oauthConfig.Client(context.Background(), token)
	httpClient.Timeout = requestTimeout

	client := twitterapi.NewClient(httpClient)

	return &Client{
		httpClient:    httpClient,
		twitterClient: client,
	}, nil
}

// Name identifies the provider.
func (c *Client) Name() string { return providerName }

// Post publishes a message (and optional image) to Twitter/X.
func (c *Client) Post(ctx context.Context, req xpost.Request) error {
	params := &twitterapi.StatusUpdateParams{}

	if req.ImagePath != "" {
		mediaID, err := c.uploadMedia(ctx, req.ImagePath)
		if err != nil {
			return fmt.Errorf("upload media: %w", err)
		}

		if req.ImageAlt != "" {
			if err := c.setAltText(ctx, mediaID, req.ImageAlt); err != nil {
				return fmt.Errorf("set alt text: %w", err)
			}
		}

		id, err := strconv.ParseInt(mediaID, 10, 64)
		if err != nil {
			return fmt.Errorf("parse media id: %w", err)
		}
		params.MediaIds = []int64{id}
	}

	_, _, err := c.twitterClient.Statuses.Update(req.Message, params)
	if err != nil {
		return fmt.Errorf("publish status: %w", err)
	}

	return nil
}

func (c *Client) uploadMedia(ctx context.Context, imagePath string) (string, error) {
	file, err := os.Open(imagePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", xpost.ValidationError{Provider: providerName, Reason: fmt.Sprintf("image %q not found", imagePath)}
		}
		return "", fmt.Errorf("open image: %w", err)
	}
	defer file.Close()

	var body bytes.Buffer
	writer := multipartWriter(&body)

	part, err := writer.CreateFormFile("media", filepath.Base(imagePath))
	if err != nil {
		return "", fmt.Errorf("create media form: %w", err)
	}
	if _, err := io.Copy(part, file); err != nil {
		return "", fmt.Errorf("copy media: %w", err)
	}

	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("finalize media form: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, mediaUploadURL, &body)
	if err != nil {
		return "", fmt.Errorf("create upload request: %w", err)
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("perform upload request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return "", fmt.Errorf("upload failed: status %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}

	var uploadResp mediaUploadResponse
	if err := json.NewDecoder(resp.Body).Decode(&uploadResp); err != nil {
		return "", fmt.Errorf("decode upload response: %w", err)
	}

	if uploadResp.MediaIDString == "" {
		return "", fmt.Errorf("upload response missing media_id")
	}

	return uploadResp.MediaIDString, nil
}

func (c *Client) setAltText(ctx context.Context, mediaID, altText string) error {
	payload := map[string]any{
		"media_id": mediaID,
		"alt_text": map[string]string{"text": altText},
	}

	buf, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal alt text payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, mediaMetadataURL, bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("create metadata request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("perform metadata request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("metadata request failed: status %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}

	return nil
}

func loadConfigFromEnv() (Config, error) {
	cfg := Config{
		ConsumerKey:    strings.TrimSpace(os.Getenv(envConsumerKey)),
		ConsumerSecret: strings.TrimSpace(os.Getenv(envConsumerSecret)),
		AccessToken:    strings.TrimSpace(os.Getenv(envAccessToken)),
		AccessSecret:   strings.TrimSpace(os.Getenv(envAccessTokenSecret)),
	}

	var missing []string
	if cfg.ConsumerKey == "" {
		missing = append(missing, envConsumerKey)
	}
	if cfg.ConsumerSecret == "" {
		missing = append(missing, envConsumerSecret)
	}
	if cfg.AccessToken == "" {
		missing = append(missing, envAccessToken)
	}
	if cfg.AccessSecret == "" {
		missing = append(missing, envAccessTokenSecret)
	}

	if len(missing) > 0 {
		return Config{}, xpost.MissingEnvError{Provider: providerName, Variables: missing}
	}

	return cfg, nil
}

// multipartWriter exists to allow deterministic gofmt imports via wrapper function.
func multipartWriter(buf *bytes.Buffer) *multipart.Writer {
	return multipart.NewWriter(buf)
}

// mediaUploadResponse models the subset of Twitter's upload response we need.
type mediaUploadResponse struct {
	MediaID       int64  `json:"media_id"`
	MediaIDString string `json:"media_id_string"`
}
