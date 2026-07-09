# ── Build & push des images du sandbox ────────────────────────────────────────
REGISTRY ?= localhost
TAG      ?= latest

CLAUDE_IMAGE  = $(REGISTRY)/claude-sandbox:$(TAG)
MCP_IMAGE     = $(REGISTRY)/mcp-remote:$(TAG)
EGRESS_IMAGE  = $(REGISTRY)/egress-proxy:$(TAG)

.PHONY: build build-claude build-mcp build-egress push clean

build: build-claude build-mcp build-egress ## Build les 3 images

build-claude:
	podman build -t $(CLAUDE_IMAGE) containers/claude

build-mcp:
	podman build -t $(MCP_IMAGE) containers/mcp-remote

build-egress:
	# Image squid officielle, config montée au runtime par le launcher
	podman pull docker.io/ubuntu/squid:latest
	podman tag docker.io/ubuntu/squid:latest $(EGRESS_IMAGE)

push: ## Push vers le registry d'équipe
	podman push $(CLAUDE_IMAGE)
	podman push $(MCP_IMAGE)
	podman push $(EGRESS_IMAGE)

clean: ## Stoppe/supprime sidecars et réseau
	-podman rm -f mcp-remote egress-proxy
	-podman network rm claude-net
