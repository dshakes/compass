# Homebrew formula for compass. This repo doubles as its own tap:
#
#   brew tap dshakes/compass https://github.com/dshakes/compass
#   brew install dshakes/compass/compass
#   compass quickstart        # wires it into ~/.claude (previews + asks first)
#
# `brew install` gets the latest tagged release; `brew install --HEAD …` tracks main.
class Compass < Formula
  desc "Senior-engineer config for Claude Code, Codex and Gemini coding agents"
  homepage "https://github.com/dshakes/compass"
  url "https://github.com/dshakes/compass/archive/refs/tags/v0.12.1.tar.gz"
  sha256 "4de009a0651938e2f7de78765da12dfc7bf3d10f7b69ee501bfd9aa9c7dc6f65"
  license "MIT"
  head "https://github.com/dshakes/compass.git", branch: "main"

  depends_on "jq"

  def install
    libexec.install Dir["*"]
    # Pin the CLI to the STABLE opt path (not the versioned Cellar path), so the symlinks
    # `compass quickstart` creates into ~/.claude survive a `brew upgrade`.
    (bin/"compass").write_env_script libexec/"bin/compass", COMPASS_REPO_ROOT: opt_libexec
  end

  def caveats
    <<~EOS
      compass is installed. Wire it into your AI assistant — it previews every change
      and asks before doing anything:

        compass quickstart

      Update:    brew upgrade compass
      Uninstall: make -C #{opt_libexec} uninstall && brew uninstall compass
    EOS
  end

  test do
    assert_match "local engineering tools", shell_output("#{bin}/compass help")
  end
end
