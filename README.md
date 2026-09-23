<p align="center">
  <a href="https://github.com/blacktop/xpost"><img alt="xpost Logo" src="docs/logo.png" height="300"/></a>
  <h4><p align="center">Cross post to all socials at once from your terminal</p></h4>
  <p align="center">
    <a href="https://github.com/blacktop/xpost/actions" alt="Actions">
          <img src="https://github.com/blacktop/xpost/actions/workflows/swift.yml/badge.svg" /></a>
    <a href="https://github.com/blacktop/xpost/releases/latest" alt="Downloads">
          <img src="https://img.shields.io/github/downloads/blacktop/xpost/total.svg" /></a>
    <a href="https://github.com/blacktop/xpost/releases" alt="GitHub Release">
          <img src="https://img.shields.io/github/release/blacktop/xpost.svg" /></a>
    <a href="http://doge.mit-license.org" alt="LICENSE">
          <img src="https://img.shields.io/:license-mit-blue.svg" /></a>
</p>
<br>

xpost posts one message to Bluesky, Mastodon and X from your terminal. Posting to X doesn't
use the paid API. xpost drives X's web composer and signs in with a passkey that Touch ID
unlocks.

## Install

```fish
brew install blacktop/tap/xpost
```

Or grab the binary from the [latest release](https://github.com/blacktop/xpost/releases/latest).
It isn't notarized, so clear the quarantine flag if you downloaded it with a browser:

```fish
xattr -d com.apple.quarantine xpost
```

Releases are for Apple Silicon Macs. On Linux, clone the repo and run `swift build -c release`.

## Set up

Configure the networks you want with environment variables.

### Bluesky

```fish
set -gx XPOST_BLUESKY_HANDLE "your.handle"
set -gx XPOST_BLUESKY_APP_PASSWORD "your_app_password"
set -gx XPOST_BLUESKY_PDS_URL "https://bsky.social"   # optional
```

### Mastodon

```fish
set -gx XPOST_MASTODON_SERVER "https://mastodon.social"
set -gx XPOST_MASTODON_ACCESS_TOKEN "your_token"
```

### X

```fish
set -gx XPOST_TWITTER_USER "your_username"
xpost twitter enroll
```

`enroll` opens a browser window. Sign in with your password, go to
*Settings > Security and account access > Security > Passkeys*, create a passkey and approve
Touch ID. The key never leaves your Mac's Secure Enclave. xpost keeps X's session in your
login keychain, so you'll only see Touch ID again when X signs you out. After an upgrade,
macOS asks once for your login password before the new binary can read that session; pick
Always Allow. `xpost twitter logout` forgets the session.

On Linux, see [X on Linux](#x-on-linux).

## Use

```sh
❱ xpost -m test --image docs/logo.webp
Posted to  Bluesky
Posted to  Mastodon
Posted to  Twitter/X
```

Pass the message as an argument, with `-m`, or on stdin. By default xpost posts to every
network you've configured and skips the rest. `--target` picks networks; repeat it or separate
names with commas. `--link` adds a URL after a blank line.

```fish
xpost "Release shipped" --target bluesky,mastodon --link https://github.com/blacktop/xpost/releases/latest
echo "Release shipped" | xpost --target twitter
xpost --dry-run -m "check it first"   # preview only: no credentials, no network
```

The limits are 300 graphemes on Bluesky, 500 characters on Mastodon and 280 on X. If one
network rejects a post, the others still get it and xpost exits non-zero. `-V` prints each
step, and `--show-browser` shows the X window so you can watch or finish a sign-in by hand.

## Posting to X

xpost uses X's website, not its API. X's terms restrict automated access, and a change to its
login or composer pages can break xpost without warning.

A post only counts as sent when X shows "Your post was sent." Anything else is reported as a
failure and never retried, since the post may have gone out anyway, so check the account
before trying again. xpost saves a screenshot of the failed page and prints its path.

xpost asks X for its English interface because it matches that confirmation in English. It
stops before pressing Post if the composer isn't in English or holds anything besides your
message, like an old unsent draft. Alt text isn't applied on X yet.

## X on Linux

On Linux, xpost drives headless Chromium through a small Node helper in `helper/`. You need
Node 22.12 or newer, pnpm and [just](https://github.com/casey/just):

```sh
swift build -c release
just helper-setup   # installs Playwright's Chromium and builds the helper
```

There's no passkey on Linux, so sign in on a Mac and export the session. Give it the numeric
id of the account you'll post as and a file that doesn't exist yet:

```fish
env XPOST_TWITTER_ACCOUNT_ID=123456789 xpost twitter export-session --output ~/.config/xpost/x-session.json
```

Sign in by hand in the window that opens. xpost checks it's the right account, then writes
the session cookies to a file only you can read. Treat that file like a password. X will
probably email you about a login from a new device; that's this.

Copy the file to the Linux machine and set:

```sh
export XPOST_TWITTER_HELPER=/path/to/xpost/helper
export XPOST_TWITTER_USER=your_username
export XPOST_TWITTER_ACCOUNT_ID=123456789   # xpost won't post as any other account
export XPOST_TWITTER_STATE_FILE=/path/to/x-session.json
```

`xpost twitter check` opens the composer without posting, so you can see whether X accepts
the session from that machine. When X ends the session, export a new one. Setting
`XPOST_TWITTER_PASSWORD` lets the helper sign in with a password instead, but X can refuse
automated sign-ins.

To work on xpost itself, run `just` to list the build, test and release tasks.

## License

MIT. See [LICENSE](LICENSE).
