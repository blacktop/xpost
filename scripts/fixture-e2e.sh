#!/bin/bash
# Drives the built xpost binary through the Chromium helper against the fixture X, so the
# Swift side, the child process contract and the helper are exercised together with no
# real account. Needs a built helper (pnpm build) with Chromium installed.
# Usage: scripts/fixture-e2e.sh <xpost binary>
set -euo pipefail

xpost=${1:?xpost binary}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'kill "$server" 2>/dev/null || true; rm -r "$work"' EXIT

# Runs a command until it succeeds, for up to five seconds.
retry() {
  for _ in $(seq 1 50); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
exited() { ! kill -0 "$1" 2>/dev/null; }
running() { pgrep -f "$1" >/dev/null; }
stopped() { ! running "$1"; }

node "$root/helper/test/fixtures/serve.ts" >"$work/url" 2>"$work/fixture.log" &
server=$!
retry test -s "$work/url" || {
  echo "the fixture X did not start"
  exit 1
}
base=$(cat "$work/url")
echo "fixture X at $base"

export XPOST_TWITTER_HELPER="$root/helper"
export XPOST_TWITTER_BASE_URL="$base"
export XPOST_TWITTER_USER=fixture_user
export XPOST_TWITTER_PASSWORD=fixture-password
export XPOST_TWITTER_ACCOUNT_ID=442174011
export XPOST_TWITTER_STATE_FILE="$work/state.json"

echo "== dry run must not touch the helper"
"$xpost" --dry-run --target twitter -m "fixture" | grep -q "would post to" || exit 1
[ ! -e "$work/state.json" ] || {
  echo "dry run wrote session state"
  exit 1
}

echo "== check signs in with the password and saves state"
"$xpost" twitter check -V | tee "$work/check.out"
grep -q "verified via password session" "$work/check.out"
[ "$(stat -c %a "$work/state.json" 2>/dev/null || stat -f %Lp "$work/state.json")" = "600" ]

echo "== check again reuses the saved state without the password"
env -u XPOST_TWITTER_PASSWORD "$xpost" twitter check | grep -q "verified via state session"

echo "== a post with an image goes through the composer"
printf '\x89PNG' >"$work/shot.png"
"$xpost" --target twitter -m "fixture post" --link https://example.com/x --image "$work/shot.png" |
  tee "$work/post.out"
grep -q "Posted to" "$work/post.out"

echo "== the wrong account is rejected before anything is posted"
export XPOST_TWITTER_ACCOUNT_ID=1
if "$xpost" --target twitter -m "must not post" 2>"$work/wrong.err"; then
  echo "posted as the wrong account"
  exit 1
fi
grep -q "wrongAccount" "$work/wrong.err"

echo "== Ctrl-C stops the helper before xpost exits"
stub="$work/stub-helper"
mkdir -p "$stub/dist"
printf 'setTimeout(() => {}, 60000);\n' >"$stub/dist/helper.js"
XPOST_TWITTER_HELPER="$stub" XPOST_TWITTER_ACCOUNT_ID=442174011 "$xpost" twitter check &
parent=$!
retry running "$stub/dist/helper.js" || {
  echo "xpost never started the helper"
  exit 1
}
kill -INT "$parent"
retry exited "$parent" || {
  echo "xpost did not exit after SIGINT"
  exit 1
}
if running "$stub/dist/helper.js"; then
  echo "the helper outlived xpost"
  exit 1
fi

echo "== Ctrl-C while the message is still being piped in"
(sleep 60 | "$xpost" --dry-run --target twitter) &
piped=$!
sleep 1
pkill -INT -f "$xpost --dry-run --target twitter" || true
retry stopped "$xpost --dry-run --target twitter" || {
  echo "xpost kept waiting for stdin after SIGINT"
  exit 1
}
kill "$piped" 2>/dev/null || true

echo "fixture end-to-end passed"
