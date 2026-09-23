#!/bin/bash
# Rewrites Formula/xpost.rb in blacktop/homebrew-tap for a published release and pushes it.
# Usage: scripts/bump-formula.sh vX.Y.Z dist/xpost_X.Y.Z_macOS_arm64.tar.gz
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <tag> <archive>" >&2
  exit 2
fi
tag=$1
archive=$2
version=${tag#v}
sha256=$(shasum -a 256 "$archive" | cut -d' ' -f1)
url="https://github.com/blacktop/xpost/releases/download/${tag}/$(basename "$archive")"

tap=$(mktemp -d)
trap 'rm -r "$tap"' EXIT
gh repo clone blacktop/homebrew-tap "$tap" -- --depth 1 --quiet

cat >"$tap/Formula/xpost.rb" <<RUBY
# typed: false
# frozen_string_literal: true

class Xpost < Formula
  desc "Cross post to all socials at once from your terminal"
  homepage "https://github.com/blacktop/xpost"
  url "${url}"
  sha256 "${sha256}"
  version "${version}"
  license "MIT"

  depends_on macos: :sequoia
  depends_on arch: :arm64

  def install
    bin.install "xpost"
    generate_completions_from_executable(bin/"xpost", "--generate-completion-script")
  end

  test do
    assert_match "Cross-post", shell_output("#{bin}/xpost --help")
  end
end
RUBY

git -C "$tap" add Formula/xpost.rb
git -C "$tap" commit --quiet -m "xpost ${version}"
git -C "$tap" push --quiet
echo "formula bumped to ${version}"
