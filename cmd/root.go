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
	linkFlag    string
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
		SilenceUsage: true,
		RunE:         runRoot,
		Example: `  xpost --message "hello world" --image ./shot.png
  xpost "Ship it!" --target twitter --target mastodon
  echo "Release shipped" | xpost --target all`,
	}

	cmd.Flags().StringVarP(&messageFlag, "message", "m", "", "Message text to post")
	cmd.Flags().StringVarP(&linkFlag, "link", "l", "", "URL to append to message (formatted with newlines)")
	cmd.Flags().StringVar(&imagePath, "image", "", "Path to an image to attach")
	cmd.Flags().StringVar(&imageAlt, "alt-text", "", "Alternative text to describe the image")
	cmd.Flags().StringSliceVar(&targetsFlag, "target", []string{"twitter", "mastodon", "bluesky"}, "Targets to post to (twitter, mastodon, bluesky, or all)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Validate and preview locally without credentials or network requests")
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
		Link:      strings.TrimSpace(linkFlag),
		ImagePath: imagePath,
		ImageAlt:  strings.TrimSpace(imageAlt),
	}
	if req.ImageAlt == "" && req.ImagePath != "" {
		req.ImageAlt = defaultAltText
	}

	if dryRun {
		// Validation and preview only use request data, so avoid constructors
		// that load credentials or create remote sessions.
		previews := map[string]xpost.Poster{
			"bluesky":  &bluesky.Client{},
			"mastodon": &mastodon.Client{},
			"twitter":  &twitter.Client{},
		}
		posters := make([]xpost.Poster, 0, len(resolvedTargets))
		for _, target := range resolvedTargets {
			poster, ok := previews[target]
			if !ok || poster == nil {
				return fmt.Errorf("preview for target %q is not implemented", target)
			}
			posters = append(posters, poster)
		}
		fmt.Fprintln(cmd.OutOrStdout(), "[dry-run] Local text preview only; credentials, uploads, and server acceptance are not checked.")
		return dispatch(ctx, posters, nil, req, cmd.OutOrStdout(), true)
	}

	posters, skips, err := buildPosters(ctx, resolvedTargets, explicitTargets(cmd))
	if err != nil {
		return err
	}

	return dispatch(ctx, posters, skips, req, cmd.OutOrStdout(), dryRun)
}

// Selecting all uses the default fan-out policy; individually named targets
// require credentials even when another target can accept the post.
func explicitTargets(cmd *cobra.Command) bool {
	if !cmd.Flags().Changed("target") {
		return false
	}
	for _, target := range targetsFlag {
		if strings.EqualFold(strings.TrimSpace(target), "all") {
			return false
		}
	}
	return true
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

// targetSkip records a target that will not receive the post.
type targetSkip struct {
	name string
	err  error
	// fatal marks skips that should fail the command. A target left out of the
	// default fan-out because it has no credentials is only informational.
	fatal bool
}

func buildPosters(ctx context.Context, targets []string, explicit bool) ([]xpost.Poster, []targetSkip, error) {
	constructors := map[string]func(context.Context) (xpost.Poster, error){
		"bluesky": func(ctx context.Context) (xpost.Poster, error) {
			return bluesky.New(ctx, bluesky.Config{PDSURL: defaultBlueskyPDSURL})
		},
		"mastodon": mastodon.New,
		"twitter":  twitter.New,
	}

	posters := make([]xpost.Poster, 0, len(targets))
	var skips []targetSkip
	for _, target := range targets {
		constructor, ok := constructors[target]
		if !ok {
			skips = append(skips, targetSkip{name: target, err: errors.New("not implemented"), fatal: true})
			continue
		}
		poster, err := constructor(ctx)
		if err != nil {
			var missing xpost.MissingEnvError
			skips = append(skips, targetSkip{
				name:  target,
				err:   err,
				fatal: explicit || !errors.As(err, &missing),
			})
			continue
		}
		posters = append(posters, poster)
	}

	// Only give up entirely when nothing is left to post to. Every reason counts
	// here, including the missing credentials that are merely informational while
	// some other target can still carry the post.
	if len(posters) == 0 {
		errs := make([]error, 0, len(skips))
		for _, skip := range skips {
			errs = append(errs, fmt.Errorf("%s: %w", skip.name, skip.err))
		}
		if len(errs) == 0 {
			return nil, nil, errors.New("no targets available")
		}
		return nil, nil, errors.Join(errs...)
	}
	return posters, skips, nil
}

func dispatch(ctx context.Context, posters []xpost.Poster, skips []targetSkip, req xpost.Request, out io.Writer, simulate bool) error {
	ready, skipped := planTargets(posters, skips, req)
	errs := reportSkips(out, skipped)

	if len(ready) == 0 {
		fmt.Fprintln(out, "No targets accepted the post")
		return errors.Join(errs...)
	}

	if simulate {
		simulatePosts(out, ready, req)
		return errors.Join(errs...)
	}

	errs = append(errs, publish(ctx, out, ready, req)...)
	return errors.Join(errs...)
}

// planTargets validates each target on its own, so a message one network
// rejects still goes out on the networks that accept it.
func planTargets(posters []xpost.Poster, skips []targetSkip, req xpost.Request) ([]xpost.Poster, []targetSkip) {
	ready := make([]xpost.Poster, 0, len(posters))
	for _, poster := range posters {
		if err := poster.Validate(req); err != nil {
			skips = append(skips, targetSkip{name: poster.Name(), err: err, fatal: true})
			continue
		}
		ready = append(ready, poster)
	}
	return ready, skips
}

func reportSkips(out io.Writer, skips []targetSkip) []error {
	errs := make([]error, 0, len(skips))
	for _, skip := range skips {
		fmt.Fprintf(out, "Skipped %s: %s\n", styledProvider(skip.name, out), skipReason(skip.err))
		if skip.fatal {
			errs = append(errs, fmt.Errorf("%s: %w", skip.name, skip.err))
		}
	}
	return errs
}

// skipReason omits provider prefixes from structured errors because the
// printed skip line already names the target.
func skipReason(err error) string {
	if invalid, ok := errors.AsType[xpost.ValidationError](err); ok {
		return invalid.Reason
	}
	if missing, ok := errors.AsType[xpost.MissingEnvError](err); ok {
		return strings.TrimPrefix(missing.Error(), missing.Provider+" ")
	}
	return err.Error()
}

func simulatePosts(out io.Writer, posters []xpost.Poster, req xpost.Request) {
	message := req.Message
	if req.Link != "" {
		message = message + "\n\n" + req.Link
	}
	for _, poster := range posters {
		preview := message
		if renderer, ok := poster.(interface{ Preview(xpost.Request) string }); ok {
			preview = renderer.Preview(req)
		}
		fmt.Fprintf(out, "[dry-run] would post to %s: %q\n", styledProvider(poster.Name(), out), preview)
	}
	if req.ImagePath != "" {
		fmt.Fprintf(out, "[dry-run] image: %s (alt: %q)\n", req.ImagePath, req.ImageAlt)
	}
}

func publish(ctx context.Context, out io.Writer, posters []xpost.Poster, req xpost.Request) []error {
	var errs []error
	for _, poster := range posters {
		if err := poster.Post(ctx, req); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", poster.Name(), err))
			fmt.Fprintf(out, "error: %s: %v\n", styledProvider(poster.Name(), out), err)
			continue
		}
		fmt.Fprintf(out, "Posted to %s\n", styledProvider(poster.Name(), out))
	}
	return errs
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
