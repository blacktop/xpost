package twitter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/blacktop/xpost/internal/logutil"
	"github.com/blacktop/xpost/internal/xpost"
	"github.com/michimani/gotwi"
	"github.com/michimani/gotwi/media/upload"
	uploadtypes "github.com/michimani/gotwi/media/upload/types"
	"github.com/michimani/gotwi/resources"
	"github.com/michimani/gotwi/tweet/managetweet"
	managetweettypes "github.com/michimani/gotwi/tweet/managetweet/types"
)

const (
	envAPIKey       = "XPOST_TWITTER_CONSUMER_KEY"
	envAPISecret    = "XPOST_TWITTER_CONSUMER_SECRET"
	envAccessToken  = "XPOST_TWITTER_ACCESS_TOKEN"
	envAccessSecret = "XPOST_TWITTER_ACCESS_TOKEN_SECRET"

	providerName = "twitter"

	metadataEndpoint = "https://upload.twitter.com/1.1/media/metadata/create.json"
)

var httpTimeout = 30 * time.Second

// Config captures the credentials required for OAuth 1.0a user-context requests.
type Config struct {
	APIKey       string
	APISecret    string
	AccessToken  string
	AccessSecret string
}

// Client implements the Poster interface for X (Twitter).
type Client struct {
	api *gotwi.Client
}

// New constructs a Twitter poster using gotwi and OAuth 1.0a credentials.
func New(ctx context.Context) (xpost.Poster, error) {
	cfg, err := loadConfigFromEnv()
	if err != nil {
		return nil, err
	}

	httpClient := &http.Client{Timeout: httpTimeout}
	debugEnabled := os.Getenv("XPOST_TWITTER_DEBUG") == "1" || logutil.Verbose()

	client, err := gotwi.NewClient(&gotwi.NewClientInput{
		HTTPClient:           httpClient,
		AuthenticationMethod: gotwi.AuthenMethodOAuth1UserContext,
		OAuthToken:           cfg.AccessToken,
		OAuthTokenSecret:     cfg.AccessSecret,
		APIKey:               cfg.APIKey,
		APIKeySecret:         cfg.APISecret,
		Debug:                debugEnabled,
	})
	if err != nil {
		return nil, fmt.Errorf("create X client: %w", err)
	}

	if !client.IsReady() {
		return nil, fmt.Errorf("twitter client not ready")
	}

	return &Client{api: client}, nil
}

// Name returns the provider identifier.
func (c *Client) Name() string { return providerName }

// Post publishes the message (and optional media) to X.
func (c *Client) Post(ctx context.Context, req xpost.Request) error {
	var mediaIDs []string
	if strings.TrimSpace(req.ImagePath) != "" {
		logutil.Debugf("uploading media: path=%s", req.ImagePath)
		mediaID, err := c.uploadMedia(ctx, req.ImagePath, req.ImageAlt)
		if err != nil {
			return err
		}
		mediaIDs = append(mediaIDs, mediaID)
		logutil.Debugf("media uploaded: media_id=%s", mediaID)
	}

	input := &managetweettypes.CreateInput{
		Text: gotwi.String(req.Message),
	}
	if len(mediaIDs) > 0 {
		input.Media = &managetweettypes.CreateInputMedia{MediaIDs: mediaIDs}
	}

	logutil.Debugf("posting tweet: media_count=%d", len(mediaIDs))
	if _, err := managetweet.Create(ctx, c.api, input); err != nil {
		return fmt.Errorf("post tweet: %w", unwrapGotwiError(err))
	}
	logutil.Debugf("tweet posted successfully")

	return nil
}

func (c *Client) uploadMedia(ctx context.Context, imagePath, altText string) (string, error) {
	data, err := os.ReadFile(imagePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", xpost.ValidationError{Provider: providerName, Reason: fmt.Sprintf("image %q not found", imagePath)}
		}
		return "", fmt.Errorf("read image: %w", err)
	}

	mediaType, category, err := resolveMediaType(imagePath, data)
	if err != nil {
		return "", err
	}

	logutil.Debugf("initialize upload: media_type=%s bytes=%d", mediaType, len(data))
	initRes, err := upload.Initialize(ctx, c.api, &uploadtypes.InitializeInput{
		MediaType:     mediaType,
		TotalBytes:    len(data),
		MediaCategory: category,
	})
	if err != nil {
		return "", fmt.Errorf("initialize upload: %w", err)
	}
	if err := partialError(initRes.Errors); err != nil {
		return "", fmt.Errorf("initialize upload: %w", err)
	}

	mediaID := initRes.Data.MediaID
	logutil.Debugf("initialize complete: media_id=%s", mediaID)

	appendIn := &uploadtypes.AppendInput{
		MediaID:      mediaID,
		Media:        bytes.NewReader(data),
		SegmentIndex: 0,
	}
	appendIn.GenerateBoundary()

	logutil.Debugf("append upload: media_id=%s segment=0", mediaID)
	appendRes, err := upload.Append(ctx, c.api, appendIn)
	if err != nil {
		return "", fmt.Errorf("append upload: %w", err)
	}
	if err := partialError(appendRes.Errors); err != nil {
		return "", fmt.Errorf("append upload: %w", err)
	}
	logutil.Debugf("append completed")

	finalizeRes, err := upload.Finalize(ctx, c.api, &uploadtypes.FinalizeInput{MediaID: mediaID})
	if err != nil {
		return "", fmt.Errorf("finalize upload: %w", err)
	}
	if err := partialError(finalizeRes.Errors); err != nil {
		return "", fmt.Errorf("finalize upload: %w", err)
	}

	state := finalizeRes.Data.ProcessingInfo.State
	logutil.Debugf("finalize state=%s media_id=%s", state, mediaID)
	switch state {
	case "", resources.ProcessingInfoStateSucceeded:
		// no-op
	case resources.ProcessingInfoStateInProgress, resources.ProcessingInfoStatePending:
		wait := time.Duration(finalizeRes.Data.ProcessingInfo.CheckAfterSecs) * time.Second
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", ctx.Err()
		case <-timer.C:
			// simple re-check by polling finalize again (images usually succeed quickly).
		}
	default:
		return "", fmt.Errorf("media processing failed: state=%s", state)
	}

	if alt := strings.TrimSpace(altText); alt != "" {
		logutil.Debugf("setting alt text: media_id=%s", mediaID)
		if err := c.setAltText(ctx, mediaID, alt); err != nil {
			return "", err
		}
	}

	return mediaID, nil
}

func (c *Client) setAltText(ctx context.Context, mediaID, altText string) error {
	params := &metadataParameters{
		mediaID: mediaID,
		altText: altText,
	}

	ctx = context.WithValue(ctx, "Content-Type", "application/json;charset=UTF-8")

	if err := c.api.CallAPI(ctx, metadataEndpoint, http.MethodPost, params, &metadataResponse{}); err != nil {
		return fmt.Errorf("set alt text: %w", unwrapGotwiError(err))
	}
	logutil.Debugf("alt text set: media_id=%s", mediaID)

	return nil
}

func loadConfigFromEnv() (Config, error) {
	cfg := Config{
		APIKey:       strings.TrimSpace(os.Getenv(envAPIKey)),
		APISecret:    strings.TrimSpace(os.Getenv(envAPISecret)),
		AccessToken:  strings.TrimSpace(os.Getenv(envAccessToken)),
		AccessSecret: strings.TrimSpace(os.Getenv(envAccessSecret)),
	}

	var missing []string
	if cfg.APIKey == "" {
		missing = append(missing, envAPIKey)
	}
	if cfg.APISecret == "" {
		missing = append(missing, envAPISecret)
	}
	if cfg.AccessToken == "" {
		missing = append(missing, envAccessToken)
	}
	if cfg.AccessSecret == "" {
		missing = append(missing, envAccessSecret)
	}

	if len(missing) > 0 {
		return Config{}, xpost.MissingEnvError{Provider: providerName, Variables: missing}
	}

	return cfg, nil
}

func resolveMediaType(path string, data []byte) (uploadtypes.MediaType, uploadtypes.MediaCategory, error) {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".jpg", ".jpeg":
		return uploadtypes.MediaTypeJPEG, uploadtypes.MediaCategoryTweetImage, nil
	case ".png":
		return uploadtypes.MediaTypePNG, uploadtypes.MediaCategoryTweetImage, nil
	case ".gif":
		return uploadtypes.MediaTypeGIF, uploadtypes.MediaCategoryTweetGIF, nil
	case ".webp":
		return uploadtypes.MediaTypeWebP, uploadtypes.MediaCategoryTweetImage, nil
	}

	// fallback to simple detection
	detected := http.DetectContentType(data)
	switch {
	case strings.Contains(detected, "jpeg"):
		return uploadtypes.MediaTypeJPEG, uploadtypes.MediaCategoryTweetImage, nil
	case strings.Contains(detected, "png"):
		return uploadtypes.MediaTypePNG, uploadtypes.MediaCategoryTweetImage, nil
	case strings.Contains(detected, "gif"):
		return uploadtypes.MediaTypeGIF, uploadtypes.MediaCategoryTweetGIF, nil
	case strings.Contains(detected, "webp"):
		return uploadtypes.MediaTypeWebP, uploadtypes.MediaCategoryTweetImage, nil
	}

	return "", "", xpost.ValidationError{Provider: providerName, Reason: fmt.Sprintf("unsupported image type for %q", path)}
}

func partialError(partials []resources.PartialError) error {
	if len(partials) == 0 {
		return nil
	}
	msgs := make([]string, 0, len(partials))
	for _, pe := range partials {
		switch {
		case pe.Detail != nil && *pe.Detail != "":
			msgs = append(msgs, *pe.Detail)
		case pe.Title != nil && *pe.Title != "":
			msgs = append(msgs, *pe.Title)
		case pe.ResourceType != nil:
			msgs = append(msgs, fmt.Sprintf("%s", *pe.ResourceType))
		}
	}
	if len(msgs) == 0 {
		msgs = append(msgs, "unknown error")
	}
	return errorsJoin(msgs)
}

func errorsJoin(messages []string) error {
	if len(messages) == 1 {
		return fmt.Errorf("%s", messages[0])
	}
	return fmt.Errorf("%s", strings.Join(messages, "; "))
}

func unwrapGotwiError(err error) error {
	var gwErr *gotwi.GotwiError
	if errors.As(err, &gwErr) && gwErr != nil {
		return fmt.Errorf("%s", summarizeGotwiError(gwErr))
	}
	return err
}

func summarizeGotwiError(err *gotwi.GotwiError) string {
	if err == nil {
		return "unknown X API error"
	}

	parts := make([]string, 0, 4)
	if err.Title != "" {
		parts = append(parts, err.Title)
	}
	if err.Detail != "" {
		parts = append(parts, err.Detail)
	}
	for _, apiErr := range err.APIErrors {
		if apiErr.Message != "" {
			parts = append(parts, apiErr.Message)
		}
	}
	if len(parts) == 0 {
		if msg := err.Error(); msg != "" {
			parts = append(parts, msg)
		}
	}
	if len(parts) == 0 {
		parts = append(parts, "X API request failed")
	}

	return strings.Join(parts, "; ")
}

type metadataParameters struct {
	mediaID     string
	altText     string
	accessToken string
}

func (p *metadataParameters) SetAccessToken(token string) {
	p.accessToken = token
}

func (p *metadataParameters) AccessToken() string {
	return p.accessToken
}

func (p *metadataParameters) ResolveEndpoint(endpointBase string) string {
	return endpointBase
}

func (p *metadataParameters) Body() (io.Reader, error) {
	body := struct {
		MediaID string `json:"media_id"`
		AltText struct {
			Text string `json:"text"`
		} `json:"alt_text"`
	}{}
	body.MediaID = p.mediaID
	body.AltText.Text = p.altText

	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return bytes.NewReader(buf), nil
}

func (p *metadataParameters) ParameterMap() map[string]string {
	return map[string]string{}
}

type metadataResponse struct{}

func (metadataResponse) HasPartialError() bool { return false }
