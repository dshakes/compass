.DEFAULT_GOAL := help
SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

quickstart: ## One command: install + validate + the 60-second on-ramp
	@./quickstart.sh

install: ## Symlink config into ~/.claude and ~/.codex (backs up existing)
	@./install.sh

install-copy: ## Copy instead of symlink
	@./install.sh --copy

dry-run: ## Show what install would do, change nothing
	@./install.sh --dry-run

uninstall: ## Remove our symlinks from ~/.claude and ~/.codex
	@./scripts/uninstall.sh

sync-plugin: ## Regenerate the plugin (plugins/core) from claude/ source
	@./scripts/sync-plugin.sh

mcp: ## Register curated MCP servers in Claude and Codex (from mcp/servers.json)
	@./scripts/setup-mcp.sh

mcp-dry: ## Preview MCP registration, change nothing
	@./scripts/setup-mcp.sh --dry-run

doctor: ## Validate JSON, TOML, hook executability, and schema sanity
	@./scripts/doctor.sh

demo: ## Render the terminal demo GIF -> demo/preview.gif (needs vhs)
	@command -v vhs >/dev/null || { echo "install vhs first:  brew install vhs"; exit 1; }
	@vhs demo/demo.tape && echo "wrote demo/preview.gif"

demo-budget: ## Render the live budget-ceiling GIF -> assets/budget.gif (needs vhs)
	@command -v vhs >/dev/null || { echo "install vhs first:  brew install vhs"; exit 1; }
	@vhs demo/budget.tape && echo "wrote assets/budget.gif"

new-repo: ## Scaffold agent config into DIR (usage: make new-repo DIR=./path [TEAM=1])
	@./scripts/new-repo.sh $(DIR) $(if $(TEAM),--team,)

apply-many: ## Apply per-repo config to many repos at once (usage: make apply-many DIRS="a b c" [TEAM=1])
	@./scripts/apply-repos.sh $(if $(TEAM),--team,) $(DIRS)

update: ## Pull latest and re-run install (for symlink installs this is just a pull)
	@git pull --ff-only && ./install.sh

.PHONY: help quickstart install install-copy dry-run uninstall doctor demo demo-budget new-repo update mcp mcp-dry sync-plugin
