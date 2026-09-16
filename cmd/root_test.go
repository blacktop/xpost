package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/blacktop/xpost/internal/xpost"
	"github.com/blacktop/xpost/internal/xpost/bluesky"
)

type fakePoster struct {
	name        string
	validateErr error
	postErr     error
	posted      bool
}

func (f *fakePoster) Name() string { return f.name }

func (f *fakePoster) Validate(xpost.Request) error { return f.validateErr }

func (f *fakePoster) Post(context.Context, xpost.Request) error {
	f.posted = true
	return f.postErr
}

func TestDispatchPostsToTargetsThatAcceptWhenAnotherRejects(t *testing.T) {
	rejected := &fakePoster{
		name:        "bluesky",
		validateErr: xpost.ValidationError{Provider: "bluesky", Reason: "message too long: 412 graphemes (max 300)"},
	}
	accepted := &fakePoster{name: "mastodon"}
	var out bytes.Buffer

	err := dispatch(t.Context(), []xpost.Poster{rejected, accepted}, nil, xpost.Request{Message: "hi"}, &out, false)

	if !accepted.posted {
		t.Error("mastodon was not posted to even though it accepted the message")
	}
	if rejected.posted {
		t.Error("bluesky was posted to despite failing validation")
	}
	if err == nil {
		t.Error("dispatch returned nil, want the rejection reported as an error")
	}

	got := out.String()
	if !strings.Contains(got, "Skipped") || !strings.Contains(got, "message too long") {
		t.Errorf("output does not explain the skip:\n%s", got)
	}
	if !strings.Contains(got, "Posted to") {
		t.Errorf("output does not report the successful post:\n%s", got)
	}
	// ValidationError already names the provider; the line should not repeat it.
	if strings.Contains(got, "bluesky validation failed") {
		t.Errorf("skip line repeats the provider name:\n%s", got)
	}
}

func TestDispatchReportsWhenEveryTargetRejects(t *testing.T) {
	first := &fakePoster{name: "bluesky", validateErr: xpost.ValidationError{Provider: "bluesky", Reason: "too long"}}
	second := &fakePoster{name: "mastodon", validateErr: xpost.ValidationError{Provider: "mastodon", Reason: "too long"}}
	var out bytes.Buffer

	err := dispatch(t.Context(), []xpost.Poster{first, second}, nil, xpost.Request{Message: "hi"}, &out, false)

	if err == nil {
		t.Error("dispatch returned nil, want an error")
	}
	if first.posted || second.posted {
		t.Error("a target was posted to despite failing validation")
	}
	if !strings.Contains(out.String(), "No targets accepted the post") {
		t.Errorf("output does not say nothing was sent:\n%s", out.String())
	}
}

func TestDispatchKeepsGoingAfterAPostFails(t *testing.T) {
	failing := &fakePoster{name: "bluesky", postErr: errors.New("create record: 502")}
	succeeding := &fakePoster{name: "mastodon"}
	var out bytes.Buffer

	err := dispatch(t.Context(), []xpost.Poster{failing, succeeding}, nil, xpost.Request{Message: "hi"}, &out, false)

	if !succeeding.posted {
		t.Error("mastodon was not posted to after bluesky failed")
	}
	if err == nil {
		t.Error("dispatch returned nil, want the post failure reported")
	}
	if !strings.Contains(out.String(), "error:") {
		t.Errorf("output does not report the failure:\n%s", out.String())
	}
}

func TestDispatchCarriesUnconfiguredTargetsWithoutFailing(t *testing.T) {
	accepted := &fakePoster{name: "mastodon"}
	skips := []targetSkip{{
		name:  "twitter",
		err:   xpost.MissingEnvError{Provider: "twitter", Variables: []string{"XPOST_TWITTER_CONSUMER_KEY"}},
		fatal: false,
	}}
	var out bytes.Buffer

	err := dispatch(t.Context(), []xpost.Poster{accepted}, skips, xpost.Request{Message: "hi"}, &out, false)

	if err != nil {
		t.Errorf("dispatch returned %v, want nil for a target that simply is not set up", err)
	}
	if !accepted.posted {
		t.Error("mastodon was not posted to")
	}
	if !strings.Contains(out.String(), "XPOST_TWITTER_CONSUMER_KEY") {
		t.Errorf("output does not name the missing credentials:\n%s", out.String())
	}
}

func TestDispatchDryRunPostsNothing(t *testing.T) {
	poster := &fakePoster{name: "mastodon"}
	var out bytes.Buffer

	if err := dispatch(t.Context(), []xpost.Poster{poster}, nil, xpost.Request{Message: "hi"}, &out, true); err != nil {
		t.Errorf("dispatch returned %v, want nil", err)
	}
	if poster.posted {
		t.Error("dry run posted for real")
	}
	if !strings.Contains(out.String(), "[dry-run]") {
		t.Errorf("output is not marked as a dry run:\n%s", out.String())
	}
}

func TestDispatchDryRunRendersBlueskyText(t *testing.T) {
	for _, req := range []xpost.Request{
		{Message: "see https://example.com/page", Link: "https://example.org/link"},
		{Message: "plain text"},
	} {
		t.Run(req.Message, func(t *testing.T) {
			// A client without credentials also proves previewing stays local.
			bsky := &bluesky.Client{}
			mastodon := &fakePoster{name: "mastodon"}
			var out bytes.Buffer
			if err := dispatch(t.Context(), []xpost.Poster{bsky, mastodon}, nil, req, &out, true); err != nil {
				t.Fatal(err)
			}
			wantBluesky := "plain text"
			wantMastodon := req.Message
			if req.Link != "" {
				wantBluesky = "see example.com/page\n\nexample.org/link"
				wantMastodon += "\n\n" + req.Link
			}
			want := fmt.Sprintf("[dry-run] would post to %s: %q\n[dry-run] would post to %s: %q\n",
				styledProvider("bluesky", &out), wantBluesky, styledProvider("mastodon", &out), wantMastodon)
			if out.String() != want {
				t.Errorf("dry-run output = %q, want %q", out.String(), want)
			}
			if mastodon.posted {
				t.Error("dry run published a post")
			}
		})
	}
}

func TestRootDryRunWithoutCredentials(t *testing.T) {
	for _, key := range []string{"XPOST_BLUESKY_HANDLE", "XPOST_BLUESKY_APP_PASSWORD", "XPOST_MASTODON_SERVER", "XPOST_MASTODON_ACCESS_TOKEN", "XPOST_TWITTER_API_KEY", "XPOST_TWITTER_CONSUMER_KEY"} {
		t.Setenv(key, "")
	}
	command := newRootCommand()
	var out bytes.Buffer
	command.SetOut(&out)
	command.SetArgs([]string{"--dry-run", "--target", "all", "--message", "see https://example.com/page", "--link", "https://example.org/link"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if strings.Count(out.String(), "[dry-run] would post to") != 3 {
		t.Fatalf("missing previews: %s", out.String())
	}
	if !strings.Contains(out.String(), `"see example.com/page\n\nexample.org/link"`) {
		t.Errorf("missing rendered Bluesky text: %s", out.String())
	}
	if !strings.Contains(out.String(), "credentials, uploads, and server acceptance are not checked") {
		t.Errorf("missing preview limitations: %s", out.String())
	}
}

func clearProviderCredentials(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"XPOST_BLUESKY_HANDLE", "XPOST_BLUESKY_APP_PASSWORD",
		"XPOST_MASTODON_SERVER", "XPOST_MASTODON_ACCESS_TOKEN",
		"XPOST_TWITTER_CONSUMER_KEY", "XPOST_TWITTER_CONSUMER_SECRET",
		"XPOST_TWITTER_ACCESS_TOKEN", "XPOST_TWITTER_ACCESS_TOKEN_SECRET",
	} {
		t.Setenv(key, "")
	}
}

func TestRootReportsErrors(t *testing.T) {
	clearProviderCredentials(t)
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"unknown flag", []string{"--targets", "all", "--dry-run", "-m", "hi"}, "unknown flag: --targets"},
		{"missing credentials", []string{"-m", "hi"}, "XPOST_MASTODON_ACCESS_TOKEN"},
		{"invalid message", []string{"--dry-run", "--target", "bluesky", "-m", strings.Repeat("a", 301)}, "message too long"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			command := newRootCommand()
			var stdout, stderr bytes.Buffer
			command.SetOut(&stdout)
			command.SetErr(&stderr)
			command.SetArgs(tc.args)
			if err := command.Execute(); err == nil {
				t.Fatal("expected command failure")
			}
			if !strings.Contains(stderr.String(), tc.want) {
				t.Errorf("stderr = %q, want %q", stderr.String(), tc.want)
			}
		})
	}
}

func TestRootAllUsesDefaultCredentialPolicy(t *testing.T) {
	clearProviderCredentials(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/statuses" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"test"}`)
	}))
	defer server.Close()
	t.Setenv("XPOST_MASTODON_SERVER", server.URL)
	t.Setenv("XPOST_MASTODON_ACCESS_TOKEN", "test-token")
	for _, tc := range []struct {
		name    string
		args    []string
		wantErr bool
	}{
		{"default", nil, false},
		{"all", []string{"--target", "all"}, false},
		{"normalized all", []string{"--target", " ALL "}, false},
		{"explicit missing provider", []string{"--target", "mastodon,bluesky"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			command := newRootCommand()
			var out bytes.Buffer
			command.SetOut(&out)
			command.SetErr(&out)
			command.SetArgs(append(tc.args, "-m", "hi"))
			err := command.Execute()
			if (err != nil) != tc.wantErr {
				t.Errorf("Execute error = %v, wantErr %v", err, tc.wantErr)
			}
			if !strings.Contains(out.String(), "Posted to") {
				t.Errorf("available provider was not posted to: %s", out.String())
			}
		})
	}
}

func TestRootRejectsMissingPreviewImplementation(t *testing.T) {
	supportedTargets["future"] = struct{}{}
	t.Cleanup(func() { delete(supportedTargets, "future") })
	command := newRootCommand()
	var out bytes.Buffer
	command.SetErr(&out)
	command.SetArgs([]string{"--dry-run", "--target", "future", "hi"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "preview for target") {
		t.Fatalf("expected missing preview error, got %v", err)
	}
}

func TestSkipReasonOmitsMissingCredentialsProvider(t *testing.T) {
	for _, variables := range [][]string{nil, {"XPOST_MASTODON_ACCESS_TOKEN"}} {
		err := xpost.MissingEnvError{Provider: "mastodon", Variables: variables}
		got := skipReason(fmt.Errorf("wrapped: %w", err))
		want := "credentials not configured"
		if len(variables) != 0 {
			want += " (missing XPOST_MASTODON_ACCESS_TOKEN)"
		}
		if got != want {
			t.Errorf("skipReason = %q, want %q", got, want)
		}
	}
}

type rejectTransport struct{ calls int }

func (r *rejectTransport) RoundTrip(*http.Request) (*http.Response, error) {
	r.calls++
	return nil, errors.New("network access forbidden in dry run")
}

func TestRootDryRunDoesNotAuthenticate(t *testing.T) {
	t.Setenv("XPOST_BLUESKY_HANDLE", "test.invalid")
	t.Setenv("XPOST_BLUESKY_APP_PASSWORD", "test-password")
	transport := &rejectTransport{}
	original := http.DefaultTransport
	http.DefaultTransport = transport
	t.Cleanup(func() { http.DefaultTransport = original })
	command := newRootCommand()
	var out bytes.Buffer
	command.SetOut(&out)
	command.SetArgs([]string{"--dry-run", "--target", "bluesky", "hello"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if transport.calls != 0 {
		t.Errorf("dry run made %d network requests", transport.calls)
	}
}
