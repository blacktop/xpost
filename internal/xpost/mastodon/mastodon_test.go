package mastodon

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/blacktop/xpost/internal/xpost"
	mastodonapi "github.com/mattn/go-mastodon"
)

func TestPostDoesNotRetryAmbiguousStatusFailure(t *testing.T) {
	for _, status := range []int{http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			attempts := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.URL.Path != "/api/v1/statuses" {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
				}
				attempts++
				// Model a proxy error after the server has accepted the post.
				if attempts == 1 {
					w.WriteHeader(status)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"id":"duplicate"}`))
			}))
			defer server.Close()
			client := &Client{client: mastodonapi.NewClient(&mastodonapi.Config{Server: server.URL, AccessToken: "token"})}
			err := client.Post(t.Context(), xpost.Request{Message: "hello"})
			var apiErr *mastodonapi.APIError
			if !errors.As(err, &apiErr) || apiErr.StatusCode != status {
				t.Errorf("Post returned %v, want original HTTP %d failure", err, status)
			}
			if attempts != 1 {
				t.Errorf("submitted status %d times, want 1", attempts)
			}
		})
	}
}

func TestPostDoesNotRetryAmbiguousMediaFailure(t *testing.T) {
	for _, status := range []int{502, 503, 504} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "image.png")
			if err := os.WriteFile(path, []byte("image data"), 0600); err != nil {
				t.Fatal(err)
			}
			uploads, posts := 0, 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/v1/statuses" {
					posts++
					w.WriteHeader(500)
					return
				}
				uploads++
				w.WriteHeader(status)
			}))
			defer server.Close()
			client := &Client{client: mastodonapi.NewClient(&mastodonapi.Config{Server: server.URL, AccessToken: "token"})}
			err := client.Post(t.Context(), xpost.Request{Message: "hello", ImagePath: path})
			var apiErr *mastodonapi.APIError
			if !errors.As(err, &apiErr) || apiErr.StatusCode != status {
				t.Errorf("Post returned %v, want HTTP %d", err, status)
			}
			if uploads != 1 || posts != 0 {
				t.Errorf("got %d uploads and %d posts, want 1 upload and no posts", uploads, posts)
			}
		})
	}
}
