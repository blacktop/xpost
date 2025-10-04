/*
Copyright © 2025 blacktop

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/blacktop/xpost/internal/logutil"
	"github.com/blacktop/xpost/internal/xpost"
	"github.com/blacktop/xpost/internal/xpost/bluesky"
	"github.com/blacktop/xpost/internal/xpost/mastodon"
	"github.com/blacktop/xpost/internal/xpost/twitter"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var (
	messageFlag string
	imagePath   string
	imageAlt    string
	targetsFlag []string
	dryRun      bool
	verbose     bool
)

var supportedTargets = map[string]struct{}{
	"bluesky":  {},
	"mastodon": {},
	"twitter":  {},
}

const (
	defaultAltText       = "Image attached via xpost"
	defaultBlueskyPDSURL = "https://bsky.social"
)

// Execute runs the root command.
func Execute() error {
	return newRootCommand().Execute()
}

func newRootCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "xpost [message]",
		Short: "Cross-post to social networks",
		Long: "xpost publishes the same update to Twitter/X, Mastodon, and Bluesky. " +
			"Provide your message as an argument or with --message and optional --image.",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE:          runRoot,
		Example: `  xpost --message "hello world" --image ./shot.png
  xpost "Ship it!" --target twitter --target mastodon
  echo "Release shipped" | xpost --targets all`,
	}

	cmd.Flags().StringVarP(&messageFlag, "message", "m", "", "Message text to post")
	cmd.Flags().StringVar(&imagePath, "image", "", "Path to an image to attach")
	cmd.Flags().StringVar(&imageAlt, "alt-text", "", "Alternative text to describe the image")
	cmd.Flags().StringSliceVar(&targetsFlag, "target", []string{"twitter", "mastodon", "bluesky"}, "Targets to post to (twitter, mastodon, bluesky, or all)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Print actions without posting")
	cmd.PersistentFlags().BoolVarP(&verbose, "verbose", "V", false, "Enable verbose logging")
	cmd.Flags().SortFlags = false

	return cmd
}

func runRoot(cmd *cobra.Command, args []string) error {
	ctx := cmd.Context()

	logutil.SetVerbose(verbose)

	message, err := resolveMessage(cmd, args)
	if err != nil {
		return err
	}

	resolvedTargets, err := normalizeTargets(targetsFlag)
	if err != nil {
		return err
	}

	req := xpost.Request{
		Message:   message,
		ImagePath: imagePath,
		ImageAlt:  strings.TrimSpace(imageAlt),
	}
	if req.ImageAlt == "" && req.ImagePath != "" {
		req.ImageAlt = defaultAltText
	}

	posters, err := buildPosters(ctx, resolvedTargets)
	if err != nil {
		return err
	}

	return dispatch(ctx, posters, req, cmd.OutOrStdout(), dryRun)
}

func resolveMessage(cmd *cobra.Command, args []string) (string, error) {
	var message string

	if messageFlag != "" {
		message = messageFlag
	}

	if len(args) > 0 {
		if message != "" {
			return "", errors.New("provide the message either as an argument or with --message, not both")
		}
		message = strings.Join(args, " ")
	}

	if message != "" {
		return strings.TrimSpace(message), nil
	}

	stdin := cmd.InOrStdin()
	if file, ok := stdin.(*os.File); ok {
		info, err := file.Stat()
		if err != nil {
			return "", fmt.Errorf("read stdin: %w", err)
		}
		if (info.Mode() & os.ModeCharDevice) == 0 {
			data, err := io.ReadAll(stdin)
			if err != nil {
				return "", fmt.Errorf("read stdin: %w", err)
			}
			message = strings.TrimSpace(string(data))
		}
	}

	if message == "" {
		return "", errors.New("message is required")
	}

	return message, nil
}

func normalizeTargets(values []string) ([]string, error) {
	if len(values) == 0 {
		return sortedTargets([]string{"twitter", "mastodon", "bluesky"}), nil
	}

	result := make([]string, 0, len(values))
	seen := map[string]struct{}{}
	for _, raw := range values {
		raw = strings.TrimSpace(strings.ToLower(raw))
		if raw == "" {
			continue
		}
		if raw == "all" {
			return sortedTargets([]string{"twitter", "mastodon", "bluesky"}), nil
		}
		if _, ok := supportedTargets[raw]; !ok {
			return nil, fmt.Errorf("unsupported target %q", raw)
		}
		if _, ok := seen[raw]; ok {
			continue
		}
		seen[raw] = struct{}{}
		result = append(result, raw)
	}

	if len(result) == 0 {
		return nil, errors.New("no targets selected")
	}

	return sortedTargets(result), nil
}

func sortedTargets(targets []string) []string {
	out := append([]string(nil), targets...)
	sort.Strings(out)
	return out
}

func buildPosters(ctx context.Context, targets []string) ([]xpost.Poster, error) {
	constructors := map[string]func(context.Context) (xpost.Poster, error){
		"bluesky": func(ctx context.Context) (xpost.Poster, error) {
			return bluesky.New(ctx, bluesky.Config{PDSURL: defaultBlueskyPDSURL})
		},
		"mastodon": func(ctx context.Context) (xpost.Poster, error) {
			return mastodon.New(ctx)
		},
		"twitter": func(ctx context.Context) (xpost.Poster, error) {
			return twitter.New(ctx)
		},
	}

	posters := make([]xpost.Poster, 0, len(targets))
	var errs []error
	for _, target := range targets {
		constructor, ok := constructors[target]
		if !ok {
			errs = append(errs, fmt.Errorf("target %q is not implemented", target))
			continue
		}
		poster, err := constructor(ctx)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", target, err))
			continue
		}
		posters = append(posters, poster)
	}

	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	if len(posters) == 0 {
		return nil, errors.New("no targets available")
	}
	return posters, nil
}

func dispatch(ctx context.Context, posters []xpost.Poster, req xpost.Request, out io.Writer, simulate bool) error {
	if simulate {
		for _, poster := range posters {
			fmt.Fprintf(out, "[dry-run] would post to %s: %q\n", styledProvider(poster.Name(), out), req.Message)
		}
		if req.ImagePath != "" {
			fmt.Fprintf(out, "[dry-run] image: %s (alt: %q)\n", req.ImagePath, req.ImageAlt)
		}
		return nil
	}

	var errs []error
	for _, poster := range posters {
		if err := poster.Post(ctx, req); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", poster.Name(), err))
			continue
		}
		fmt.Fprintf(out, "Posted to %s\n", styledProvider(poster.Name(), out))
	}

	if len(errs) > 0 {
		for _, err := range errs {
			fmt.Fprintf(out, "error: %v\n", err)
		}
		return errors.Join(errs...)
	}
	return nil
}

type providerStyle struct {
	icon  string
	label string
	color string
}

const (
	colorReset    = "\033[0m"
	twitterColor  = "\033[38;5;39m"
	mastodonColor = "\033[38;5;63m"
	blueskyColor  = "\033[38;5;45m"
	iconTwitter   = "\uf099"
	iconMastodon  = "\uedc0"
	iconBluesky   = "\ue28e" // butterfly as a playful Bluesky glyph
)

var providerStyles = map[string]providerStyle{
	"twitter":  {icon: iconTwitter, label: "Twitter/X", color: twitterColor},
	"mastodon": {icon: iconMastodon, label: "Mastodon", color: mastodonColor},
	"bluesky":  {icon: iconBluesky, label: "Bluesky", color: blueskyColor},
}

func styledProvider(name string, out io.Writer) string {
	style, ok := providerStyles[name]
	if !ok {
		return name
	}
	text := fmt.Sprintf("%s %s", style.icon, style.label)
	return colorize(out, text, style.color)
}

func colorize(out io.Writer, text, color string) string {
	if !supportsColor(out) || color == "" {
		return text
	}
	return color + text + colorReset
}

func supportsColor(w io.Writer) bool {
	if os.Getenv("NO_COLOR") != "" {
		return false
	}
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	return term.IsTerminal(int(f.Fd()))
}
