package bluesky

import (
	"strings"
	"testing"

	"github.com/blacktop/xpost/internal/xpost"
)

func TestShortenURL(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "bare host", raw: "https://example.com", want: "example.com"},
		{name: "root path", raw: "https://example.com/", want: "example.com"},
		{name: "path at the limit", raw: "https://github.com/blacktop/xpost", want: "github.com/blacktop/xpost"},
		{name: "long path", raw: "https://github.com/blacktop/xpost/releases/latest", want: "github.com/blacktop/xpo..."},
		{name: "short query", raw: "https://example.com/a?b=c", want: "example.com/a?b=c"},
		{name: "long query", raw: "https://example.com/search?q=something+long+here", want: "example.com/search?q=som..."},
		{name: "non http scheme is untouched", raw: "ftp://example.com/files/archive", want: "ftp://example.com/files/archive"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shortenURL(tt.raw); got != tt.want {
				t.Errorf("shortenURL(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestRenderPostLinksFullURLBehindShortLabel(t *testing.T) {
	const full = "https://github.com/blacktop/xpost/releases/latest"
	text, facets := renderPost("check " + full + " out")

	if want := "check github.com/blacktop/xpo... out"; text != want {
		t.Errorf("text = %q, want %q", text, want)
	}
	if len(facets) != 1 {
		t.Fatalf("got %d facets, want 1", len(facets))
	}

	facet := facets[0]
	if got := facet.Features[0].RichtextFacet_Link.Uri; got != full {
		t.Errorf("facet uri = %q, want the complete URL %q", got, full)
	}
	if got := sliceFacet(t, text, facet.Index.ByteStart, facet.Index.ByteEnd); got != "github.com/blacktop/xpo..." {
		t.Errorf("facet covers %q, want the shortened label", got)
	}
}

func TestRenderPostByteOffsetsSurviveMultibyteText(t *testing.T) {
	const full = "https://example.com/very/long/path/here"
	text, facets := renderPost("🎉 " + full)

	if len(facets) != 1 {
		t.Fatalf("got %d facets, want 1", len(facets))
	}
	// The emoji is 4 bytes, so a rune-based offset here would point into the middle of it.
	if got := sliceFacet(t, text, facets[0].Index.ByteStart, facets[0].Index.ByteEnd); got != "example.com/very/long/pa..." {
		t.Errorf("facet covers %q, want the shortened label", got)
	}
}

func TestRenderPostLeavesTrailingPunctuationOutOfTheLink(t *testing.T) {
	text, facets := renderPost("see https://example.com/page.")

	if want := "see example.com/page."; text != want {
		t.Errorf("text = %q, want %q", text, want)
	}
	if len(facets) != 1 {
		t.Fatalf("got %d facets, want 1", len(facets))
	}
	if got := facets[0].Features[0].RichtextFacet_Link.Uri; got != "https://example.com/page" {
		t.Errorf("facet uri = %q, want the period excluded", got)
	}
	if got := sliceFacet(t, text, facets[0].Index.ByteStart, facets[0].Index.ByteEnd); got != "example.com/page" {
		t.Errorf("facet covers %q, want the period excluded", got)
	}
}

func TestRenderPostWithoutLinks(t *testing.T) {
	text, facets := renderPost("no links here")

	if text != "no links here" {
		t.Errorf("text = %q, want it unchanged", text)
	}
	if facets != nil {
		t.Errorf("facets = %v, want nil", facets)
	}
}

func TestRenderPostPreservesBalancedURLParentheses(t *testing.T) {
	text, facets := renderPost("(https://example.com/a(b)).")
	if text != "(example.com/a(b))." {
		t.Errorf("rendered text = %q", text)
	}
	if len(facets) != 1 {
		t.Fatalf("got %d facets, want 1", len(facets))
	}
	if got := facets[0].Features[0].RichtextFacet_Link.Uri; got != "https://example.com/a(b)" {
		t.Errorf("facet URI = %q, includes sentence punctuation", got)
	}
	if got := sliceFacet(t, text, facets[0].Index.ByteStart, facets[0].Index.ByteEnd); got != "example.com/a(b)" {
		t.Errorf("facet label = %q, want balanced URL parentheses only", got)
	}
}

func TestValidateCountsTheShortenedLink(t *testing.T) {
	// A URL that blows the 300-grapheme budget at full length but fits once shortened.
	long := "https://example.com/" + strings.Repeat("a", 400)

	if err := (&Client{}).Validate(xpost.Request{Message: "ship it", Link: long}); err != nil {
		t.Errorf("Validate rejected a post whose link shortens to well under the limit: %v", err)
	}
}

func TestValidateStillRejectsLongProse(t *testing.T) {
	if err := (&Client{}).Validate(xpost.Request{Message: strings.Repeat("a", maxGraphemes+1)}); err == nil {
		t.Error("Validate accepted a message over the grapheme limit")
	}
}

// sliceFacet returns the substring a facet's byte range points at, failing the
// test if the range is out of bounds.
func sliceFacet(t *testing.T, text string, start, end int64) string {
	t.Helper()
	if start < 0 || end > int64(len(text)) || start > end {
		t.Fatalf("facet range [%d,%d) is out of bounds for %d bytes", start, end, len(text))
	}
	return text[start:end]
}
