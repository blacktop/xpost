set positional-arguments

default:
    @just --list

# Build the current checkout.
build:
    swift build

# Run the Swift tests without account credentials.
test:
    swift test

# Check Swift formatting.
lint:
    swift format lint --strict --recursive Package.swift Sources Tests

# Install Chromium and its system dependencies, then build the helper.
helper-setup:
    pnpm --dir helper install --frozen-lockfile
    pnpm --dir helper exec playwright install --with-deps chromium
    pnpm --dir helper build

# Build the helper and test against local fixtures.
helper-test:
    pnpm --dir helper test

# Follow xpost's unified log (macOS).
logs:
    /usr/bin/log stream --style compact --predicate 'subsystem == "io.blacktop.xpost"'

# Preview all targets without signing in or posting.
preview message="xpost smoke test":
    swift run xpost --dry-run --target all -m "$1"

# Preview an image post without signing in or posting.
preview-image message="image smoke test" image="docs/logo.webp":
    swift run xpost --dry-run --target mastodon --image "$2" -m "$1"

# Inspect X's login page without signing in (macOS).
twitter-probe:
    swift run xpost twitter probe --show-browser

# Create or replace the X passkey interactively (macOS).
twitter-enroll:
    swift run xpost twitter enroll

# Sign in manually and export a session for Linux (macOS, no post).
[no-cd]
twitter-export-session output:
    swift run --package-path {{quote(justfile_directory())}} xpost twitter export-session --output "$1"

# Forget the saved X session, keeping the passkey (macOS).
twitter-logout:
    swift run xpost twitter logout

# Publish a real Bluesky post.
post-bluesky message="xpost smoke test: Bluesky":
    swift run xpost --target bluesky -m "$1"

# Publish a real Mastodon post with an image.
post-mastodon message="xpost smoke test: Mastodon attachment" image="docs/logo.webp":
    swift run xpost --target mastodon --image "$2" -m "$1"

# Publish a real X post with the browser visible (macOS).
post-twitter message="xpost smoke test: X passkey":
    swift run xpost --target twitter --show-browser -m "$1"

# Release build signed with a stable identity, so the keychain keeps trusting it (macOS).
sign:
    #!/usr/bin/env bash
    # SIGN_IDENTITY overrides the default: Developer ID, else Apple Development.
    set -euo pipefail
    identity="${SIGN_IDENTITY:-$("{{ just_executable() }}" signing-identity)}"
    [ -n "$identity" ] || { echo "no code-signing identity found; set SIGN_IDENTITY"; exit 1; }
    echo "🚀 Building and signing with $identity"
    swift build -c release
    bin="$(swift build -c release --show-bin-path)/xpost"
    codesign --force --sign "$identity" --identifier io.blacktop.xpost --options runtime "$bin"
    codesign --verify --strict --verbose=2 "$bin"
    echo "signed: $bin"

# Tag the next version (patch, minor or major); the Release workflow publishes it.
bump level="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🚀 Bumping Version"
    tag=$(svu "$1")
    git tag -a "$tag" -m "Release $tag"
    git push --tags

# The first Developer ID Application identity in the keychain, else the first Apple
# Development one.
[private]
signing-identity:
    #!/usr/bin/env bash
    set -euo pipefail
    security find-identity -v -p codesigning | awk -F '"' '
      /"Developer ID Application: / { developer = $2; exit }
      /"Apple Development: / && !development { development = $2 }
      END { print developer ? developer : development }'
