# Homebrew formula for compass. This repo doubles as its own tap:
#
#   brew tap dshakes/compass https://github.com/dshakes/compass
#   brew install dshakes/compass/compass
#   compass quickstart        # wires it into ~/.claude (previews + asks first)
#
# `brew install` gets the latest tagged release; `brew install --HEAD …` tracks main.
class Compass < Formula
  desc "Measured guardrails, a budget cap, and a self-fixing loop for AI coding agents"
  homepage "https://github.com/dshakes/compass"
  url "https://github.com/dshakes/compass/archive/refs/tags/v0.21.0.tar.gz"
  sha256 "ef7e824c1aa0b22db8b8a5253d0d839eb44e0c7f8c30775ac5197611e3e8dd2f"
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
    # Assert on stable exit codes, not help copy (which edits often): `help` must
    # succeed, and an unknown subcommand must exit 2 (bin/compass's `*)` arm).
    system bin/"compass", "help"
    shell_output("#{bin}/compass __no_such_cmd__ 2>&1", 2)
  end
end
