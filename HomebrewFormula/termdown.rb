class Termdown < Formula
  desc "Preview Markdown in Rex terminal panes, paired with your Claude Code agents"
  homepage "https://github.com/tarvy/termdown"
  url "https://github.com/tarvy/termdown.git", tag: "termdown-v0.5.2", revision: "91da40e31cf0fcdc70ca9085a779e37ab3fe9202"
  version "0.5.2"

  depends_on macos: :sonoma

  resource "swift-cmark" do
    url "https://github.com/swiftlang/swift-cmark/archive/437611671145d47e6d9679761b8a5987766f4ae5.tar.gz"
    sha256 "bcc825cecd1710cdca28f7cc0a74423a691966be2f3a4c6fa8739a2009ed5bf2"
  end

  def install
    swift_major = Utils.safe_popen_read("swift", "--version")[/Swift version (\d+)/, 1].to_i
    odie "termdown needs Swift 6 or later: xcode-select --install" if swift_major < 6

    source_version = File.read("Sources/TermDownCore/Version.swift")[/termDownVersion = "([^"]+)"/, 1]
    odie "Version.swift says #{source_version}, formula says #{version}" if source_version != version.to_s

    resource("swift-cmark").stage(buildpath/"vendor/swift-cmark")
    inreplace "Package.swift",
              '.package(url: "https://github.com/swiftlang/swift-cmark", revision: "437611671145d47e6d9679761b8a5987766f4ae5")',
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
