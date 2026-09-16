package bluesky

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/blacktop/xpost/internal/xpost"
	"github.com/bluesky-social/indigo/api/atproto"
	"github.com/bluesky-social/indigo/api/bsky"
	"github.com/bluesky-social/indigo/lex/util"
	"github.com/bluesky-social/indigo/xrpc"
	"github.com/rivo/uniseg"
)

const (
	envHandle      = "XPOST_BLUESKY_HANDLE"
	envAppPassword = "XPOST_BLUESKY_APP_PASSWORD"
	envPDSURL      = "XPOST_BLUESKY_PDS_URL"

	providerName   = "bluesky"
	requestTimeout = 30 * time.Second
	maxGraphemes   = 300 // Bluesky's post character limit in graphemes

	// Link display limits mirror the Bluesky composer: a path longer than
	// maxPathDisplay is cut to pathTruncateAt characters plus an ellipsis.
	maxPathDisplay = 15
	pathTruncateAt = 13
)

// urlRegex matches URLs in text for creating link facets
var urlRegex = regexp.MustCompile(`https?://[^\s]+`)

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

// Preview returns the rendered post text without making network requests.
func (c *Client) Preview(req xpost.Request) string {
	text, _ := renderPost(compose(req))
	return text
}

// Validate checks if the request meets Bluesky's constraints. Links are counted
// at their shortened display length, which is what the post will actually carry.
func (c *Client) Validate(req xpost.Request) error {
	text := c.Preview(req)
	count := uniseg.GraphemeClusterCount(text)
	if count > maxGraphemes {
		return xpost.ValidationError{
			Provider: providerName,
			Reason:   fmt.Sprintf("message too long: %d graphemes (max %d)", count, maxGraphemes),
		}
	}
	return nil
}

// Post creates a new Bluesky post with an optional image embed.
func (c *Client) Post(ctx context.Context, req xpost.Request) error {
	text, facets := renderPost(compose(req))

	post := &bsky.FeedPost{
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		Text:      text,
		Facets:    facets,
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

// compose joins the message and the optional link into the post body.
func compose(req xpost.Request) string {
	if req.Link == "" {
		return req.Message
	}
	return req.Message + "\n\n" + req.Link
}

// renderPost rewrites every URL in text to its short display form and returns
// the rewritten text along with facets pointing at the full URLs. Only the
// short label occupies the post body, so a long URL costs a handful of
// graphemes against the 300 limit instead of its full length.
func renderPost(text string) (string, []*bsky.RichtextFacet) {
	matches := urlRegex.FindAllStringIndex(text, -1)
	if len(matches) == 0 {
		return text, nil
	}

	var body strings.Builder
	facets := make([]*bsky.RichtextFacet, 0, len(matches))
	cursor := 0

	for _, match := range matches {
		link, trailing := splitTrailingPunct(text[match[0]:match[1]])
		if link == "" {
			continue
		}

		body.WriteString(text[cursor:match[0]])
		start := body.Len()
		body.WriteString(shortenURL(link))

		facets = append(facets, &bsky.RichtextFacet{
			Index: &bsky.RichtextFacet_ByteSlice{
				ByteStart: int64(start),
				ByteEnd:   int64(body.Len()),
			},
			Features: []*bsky.RichtextFacet_Features_Elem{
				{
					RichtextFacet_Link: &bsky.RichtextFacet_Link{
						LexiconTypeID: "app.bsky.richtext.facet#link",
						Uri:           link,
					},
				},
			},
		})

		body.WriteString(trailing)
		cursor = match[1]
	}

	body.WriteString(text[cursor:])

	if len(facets) == 0 {
		return text, nil
	}
	return body.String(), facets
}

// splitTrailingPunct peels sentence punctuation off a matched URL so that
// "see https://example.com/page." links the page and leaves the period as text.
func splitTrailingPunct(match string) (string, string) {
	end := len(match)
	excessClosing := strings.Count(match, ")") - strings.Count(match, "(")
	for end > 0 {
		switch c := match[end-1]; {
		case c == '.' || c == ',' || c == ';' || c == '!' || c == '?':
			end--
		case c == ')' && excessClosing > 0:
			end--
			excessClosing--
		default:
			return match[:end], match[end:]
		}
	}
	return match[:end], match[end:]
}

// shortenURL renders a URL the way the Bluesky composer does: drop the scheme
// and truncate a long path. Mirrors toShortUrl in bluesky-social/social-app.
func shortenURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return raw
	}

	path := parsed.EscapedPath()
	if path == "/" {
		path = ""
	}
	if parsed.RawQuery != "" {
		path += "?" + parsed.RawQuery
	}
	if parsed.Fragment != "" {
		path += "#" + parsed.EscapedFragment()
	}

	if utf8.RuneCountInString(path) > maxPathDisplay {
		return parsed.Host + string([]rune(path)[:pathTruncateAt]) + "..."
	}
	return parsed.Host + path
}
