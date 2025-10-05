<p align="center">
  <a href="https://github.com/blacktop/xpost"><img alt="xpost Logo" src="https://raw.githubusercontent.com/blacktop/xpost/main/docs/logo.webp" height="200"/></a>
  <h4><p align="center">Cross post to all socials at once from your terminal</p></h4>
  <p align="center">
    <a href="https://github.com/blacktop/xpost/actions" alt="Actions">
          <img src="https://github.com/blacktop/xpost/actions/workflows/go.yml/badge.svg" /></a>
    <a href="https://github.com/blacktop/xpost/releases/latest" alt="Downloads">
          <img src="https://img.shields.io/github/downloads/blacktop/xpost/total.svg" /></a>
    <a href="https://github.com/blacktop/xpost/releases" alt="GitHub Release">
          <img src="https://img.shields.io/github/release/blacktop/xpost.svg" /></a>
    <a href="http://doge.mit-license.org" alt="LICENSE">
          <img src="https://img.shields.io/:license-mit-blue.svg" /></a>
</p>
<br>

## Supported Socials

- [x] X/Twitter
- [x] Mastodon
- [x] BlueSky 

## Getting Started

### Install

Via [homebrew](https://brew.sh)

```bash
brew install blacktop/tap/xpost
```

Via [Golang](https://go.dev/dl/)

```bash
go install github.com/blacktop/xpost@latest
```

Or download the latest [release](https://github.com/blacktop/xpost/releases/latest)

### Configuration

Set environment variables for the platforms you want to use:

**Twitter/X**
```bash
export XPOST_TWITTER_CONSUMER_KEY="your_key"
export XPOST_TWITTER_CONSUMER_SECRET="your_secret"
export XPOST_TWITTER_ACCESS_TOKEN="your_token"
export XPOST_TWITTER_ACCESS_TOKEN_SECRET="your_token_secret"
```

**Mastodon**
```bash
export XPOST_MASTODON_SERVER="https://mastodon.social"
export XPOST_MASTODON_ACCESS_TOKEN="your_token"
export XPOST_MASTODON_CLIENT_ID="your_client_id"
export XPOST_MASTODON_CLIENT_SECRET="your_client_secret"
```

**BlueSky**
```bash
export XPOST_BLUESKY_HANDLE="your.handle"
export XPOST_BLUESKY_APP_PASSWORD="your_app_password"
```

### Usage

Send message to all supported networks

```bash
❱ xpost -m test --image docs/logo.webp
Posted to  Bluesky
Posted to  Mastodon
Posted to  Twitter/X
```

## License

MIT Copyright (c) 2025 **blacktop**