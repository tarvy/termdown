#!/bin/sh
# Writes the Homebrew formula for a release into this repository's HomebrewFormula/ folder.
#
#   scripts/release.sh X.Y.Z          formula pinned to the tag termdown-vX.Y.Z (the tag must exist locally)
#   scripts/release.sh --local X.Y.Z  formula for testing: pinned to HEAD, written to $TMPDIR/termdown.rb
#
# Users install with:  brew tap tarvy/termdown https://github.com/tarvy/termdown && brew install termdown
set -eu

usage() {
  echo "usage: release.sh [--local] <version>" >&2
  exit 64
}

local_mode=0
if [ "${1:-}" = "--local" ]; then
  local_mode=1
  shift
fi
[ "$#" -eq 1 ] || usage

version=$1
case "$version" in
  *[!0-9.]* | "") usage ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
declared=$(sed -n 's/^public let termDownVersion = "\(.*\)"$/\1/p' "$root/Sources/TermDownCore/Version.swift")
if [ "$declared" != "$version" ]; then
  echo "Version.swift declares $declared; update it to $version and commit before releasing." >&2
  exit 1
fi

tag="termdown-v$version"
if [ "$local_mode" -eq 1 ]; then
  revision=$(git -C "$root" rev-parse HEAD)
  url_line="url \"file://$root\", using: :git, revision: \"$revision\""
  formula="${TMPDIR:-/tmp}/termdown.rb"
else
  if ! git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag does not exist. Tag the commit that sets the version first: git tag $tag <commit>" >&2
    exit 1
  fi
  revision=$(git -C "$root" rev-list -n 1 "$tag")
  url_line="url \"https://github.com/tarvy/termdown.git\", tag: \"$tag\", revision: \"$revision\""
  formula="$root/HomebrewFormula/termdown.rb"
  mkdir -p "$(dirname "$formula")"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

manifest="$root/Package.swift"
cmark_line=$(grep -o '\.package(url: "https://github.com/swiftlang/swift-cmark", revision: "[0-9a-f]*")' "$manifest")
cmark_revision=$(printf '%s' "$cmark_line" | sed 's/.*revision: "\([0-9a-f]*\)".*/\1/')
if [ -z "$cmark_revision" ]; then
  echo "could not find the pinned swift-cmark revision in $manifest" >&2
  exit 1
fi
cmark_url="https://github.com/swiftlang/swift-cmark/archive/$cmark_revision.tar.gz"
curl --fail --location --silent --show-error --output "$work/swift-cmark.tar.gz" "$cmark_url"
cmark_sha=$(shasum -a 256 "$work/swift-cmark.tar.gz" | cut -d' ' -f1)

cat > "$formula" <<RUBY
class Termdown < Formula
  desc "Preview Markdown in Rex terminal panes, paired with your Claude Code agents"
  homepage "https://github.com/tarvy/termdown"
  $url_line
  version "$version"

  depends_on macos: :sonoma

  resource "swift-cmark" do
    url "$cmark_url"
    sha256 "$cmark_sha"
  end

  def install
    swift_major = Utils.safe_popen_read("swift", "--version")[/Swift version (\d+)/, 1].to_i
    odie "termdown needs Swift 6 or later: xcode-select --install" if swift_major < 6

    source_version = File.read("Sources/TermDownCore/Version.swift")[/termDownVersion = "([^"]+)"/, 1]
    odie "Version.swift says #{source_version}, formula says #{version}" if source_version != version.to_s

    resource("swift-cmark").stage(buildpath/"vendor/swift-cmark")
    inreplace "Package.swift",
              '$cmark_line',
              '.package(path: "vendor/swift-cmark")'
    rm "Package.resolved"
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/termdown"
    libexec.install ".build/release/termdown_TermDownRender.bundle"
    libexec.install ".build/release/termdown_TermDownMermaid.bundle"
    system "scripts/build-app.sh", ".build/release/TermDownHandler", version.to_s, libexec
  end

  def caveats
    <<~EOS
      Finish setup (handler app, Rex palette actions, agent skills):
        termdown setup
      After brew upgrade termdown, rerun termdown setup.
      To undo: termdown uninstall && brew uninstall termdown
    EOS
  end

  test do
    assert_match "usage", shell_output("#{bin}/termdown --help").downcase
    assert_match version.to_s, shell_output("#{bin}/termdown --version")
  end
end
RUBY

echo "wrote $formula"
