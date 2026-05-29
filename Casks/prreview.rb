cask "prreview" do
  version "0.1.0"
  sha256 "e6befa72904a49bbb6317f38b44e18f9104352128d2c033b4c95cddea79ef652"

  url "https://github.com/ordishs/code-reviewer/releases/download/v#{version}/PRReview-#{version}.dmg"
  name "PR Review"
  desc "Native macOS PR review workflow with embedded Claude terminal and native diff"
  homepage "https://github.com/ordishs/code-reviewer"

  depends_on macos: ">= :sonoma"
  depends_on formula: "gh"

  app "PRReview.app"

  zap trash: [
    "~/Library/Application Support/PRReview",
    "~/Library/Preferences/com.ordishs.PRReview.plist",
    "~/Library/Saved Application State/com.ordishs.PRReview.savedState",
  ]
end
