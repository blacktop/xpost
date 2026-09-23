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

## Supported socials

- [x] Bluesky
- [x] Mastodon
- [x] X/Twitter, through the web composer with a Touch ID passkey (no API credits)

On macOS, xpost is a single binary for Apple Silicon. On Linux you build it from source, and
posting to X also needs a small Node helper that drives headless Chromium (see
[Linux](#linux)).

## Getting started

### Install

Via [homebrew](https://brew.sh)

```sh
brew install blacktop/tap/xpost
```

Or download the latest [release](https://github.com/blacktop/xpost/releases/latest). The
binary isn't notarized, so macOS blocks a copy downloaded with a browser until you clear its
quarantine flag:

```fish
xattr -d com.apple.quarantine xpost
```

### Configuration

Set environment variables for the networks you want to post to. In fish:

**Bluesky**

```fish
set -gx XPOST_BLUESKY_HANDLE "your.handle"
set -gx XPOST_BLUESKY_APP_PASSWORD "your_app_password"
set -gx XPOST_BLUESKY_PDS_URL "https://bsky.social"   # optional
```

**Mastodon**

```fish
set -gx XPOST_MASTODON_SERVER "https://mastodon.social"
set -gx XPOST_MASTODON_ACCESS_TOKEN "your_token"
```

**X/Twitter**

```fish
set -gx XPOST_TWITTER_USER "your_username"
xpost twitter enroll
```

`enroll` opens a browser window. Sign in with your password, go to
*Settings > Security and account access > Security > Passkeys*, create a passkey, and approve
the Touch ID prompt. The passkey's private key lives in this Mac's Secure Enclave and only
signs after Touch ID (or your login password). xpost keeps its record of the passkey at
`~/.config/xpost/twitter-passkey.json`. X's session cookies go in your login keychain, so
you'll only see Touch ID again when X ends the session. After each upgrade, macOS asks once
for your login password before the new xpost can read that saved session; choose Always
Allow. `xpost twitter logout` forgets the saved session.

Networks you haven't configured are skipped when you post to all of them. If you name one
with `--target`, that's an error instead.

### Usage

Send a message to every configured network

```sh
❱ xpost -m test --image docs/logo.webp
Posted to  Bluesky
Posted to  Mastodon
Posted to  Twitter/X
```

Preview without credentials or network access

```sh
❱ xpost --dry-run --target bluesky,mastodon "Release shipped" --link https://github.com/blacktop/xpost/releases/latest
```

The message can be an argument, `-m/--message`, or piped on stdin. `--link` goes after a
blank line, and Bluesky shows it shortened and counts it that way. The limits are 300
graphemes on Bluesky, 500 characters on Mastodon and 280 on X. If one network rejects a
message, the others still get it and xpost exits non-zero.

`--show-browser` shows the X browser window, so you can watch a sign-in or finish one by
hand. On macOS, run details go to the unified log, which you can read in Console or with
`log`. `-V/--verbose` also prints each step to stderr.

```sh
log show --last 10m --predicate 'subsystem == "io.blacktop.xpost"'
```

### About posting to X

xpost posts to X by driving X's web composer in a browser, not through the API. X's terms of
service restrict automated access, and a change to X's login or composer pages can break this
without warning.

When a post fails, xpost saves a screenshot of the page to your temporary directory and prints
the path. Alt text isn't applied on X yet. A post only counts as sent when X shows its "Your
post was sent." confirmation. Anything else is reported as a failure and never retried, since
the post may have gone out anyway.

Both browser backends ask X for an English interface, because that confirmation is matched in
English. If the composer still declares another language (or none), xpost stops before
pressing Post. It doesn't change your account's language setting. It also stops there if the
composer holds anything besides your message, like a partial paste or an old unsent draft.

## Linux

Bluesky and Mastodon need nothing but the binary. For X, xpost runs `helper/`, a Playwright
program, as a child process. The helper needs Node 22.12 or newer, pnpm, and Playwright's
Chromium with its system libraries. With [just](https://github.com/casey/just) installed:

```sh
swift build -c release
just helper-setup   # pnpm install, playwright install --with-deps chromium, build
```

Then set these in the environment xpost runs in:

```sh
XPOST_TWITTER_HELPER=/path/to/xpost/helper   # the directory with dist/helper.js
XPOST_TWITTER_USER=dedicated_account         # typed into the login form
XPOST_TWITTER_ACCOUNT_ID=442174011           # X's numeric id of that account; nothing else may post
XPOST_TWITTER_PASSWORD=…                     # or a saved session:
XPOST_TWITTER_STATE_FILE=/secure/x-session.json
```

Use a dedicated account. The helper only signs in with the password when there's no saved
session or the saved one no longer works. Before it saves anything or posts, it checks X's own
`twid` cookie to confirm the signed-in account is `XPOST_TWITTER_ACCOUNT_ID`. If X asks for a
phone number, email, code or CAPTCHA (a "challenge"), the helper stops. It never tries to get
past one.

The state file is a credential because it holds the session cookies. xpost writes it with
mode 0600 after a verified password login and reads it on later runs. Keep it out of build
caches, logs and uploaded artifacts, and delete it to sign out.

`xpost twitter check` signs in, verifies the account and opens the composer without posting.
Use it to find out whether X accepts a login from a given machine. The two workflows in
`.github/workflows` split the work: `swift.yml` only ever talks to a fixture server, while
`x-live-check.yml` runs by hand against the real X and never posts. Its account lives in the
secrets of a GitHub environment named `x-live`, so give that environment required reviewers.
The live check is also the only way to learn whether X keeps accepting unattended logins from
a hosted runner. The fixtures can't tell you that.

## Development

Development tasks live in the [justfile](justfile); run `just` to list them. The recipes use
the current checkout and inherit the environment variables above. `just helper-setup` also
installs Chromium's Linux system dependencies and builds the helper.

On macOS, `just logs` follows xpost's unified log. The recipes keep verbose terminal output
off, but enrollment instructions and command results still show up in the terminal.

```fish
just build           # swift build
just test            # swift test
just lint            # swift format lint
just helper-setup
just helper-test     # helper tests against the local fixture X
just preview         # dry run to every network
just twitter-probe
```

`just twitter-enroll` sets up the Mac passkey, and `just twitter-logout` clears the saved X
session. The `post-bluesky`, `post-mastodon` and `post-twitter` recipes publish real posts.
Each takes an optional message, for example `just post-bluesky "My test post"`.
`post-mastodon` and `preview-image` also take an image path after the message, which defaults
to `docs/logo.webp`.

```fish
just sign      # release build signed with a stable identity, so the keychain keeps trusting it
just bump      # tag the next patch version and push it (`just bump major` for a major)
```

Pushing a version tag runs the Release workflow, which builds the tag on macOS, publishes the
GitHub release and points the Homebrew formula at it.

Every `swift build` signs the binary differently, and the login keychain asks for your
password each time a new binary reads the saved X session. `just sign` fixes that for the
binary you actually use. It picks your Developer ID certificate, or else an Apple Development
one; to choose another, run `env SIGN_IDENTITY="…" just sign`.

## License

MIT License - see [LICENSE](LICENSE) for details.
