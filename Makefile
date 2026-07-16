# ── Build & push des images du sandbox ────────────────────────────────────────
REGISTRY ?= localhost
TAG      ?= latest
PROFILE  ?= claude

BASE_IMAGE    = $(REGISTRY)/agent-base:$(TAG)
HARNESS_IMAGE = $(REGISTRY)/agent-$(PROFILE):$(TAG)
MCP_IMAGE     = $(REGISTRY)/mcp-remote:$(TAG)
EGRESS_IMAGE  = $(REGISTRY)/egress-proxy:$(TAG)

.PHONY: build build-base build-harness build-mcp build-egress push clean

build: build-base build-harness build-mcp build-egress ## Build base + harness ($(PROFILE)) + sidecars

build-base: ## Build l'image socle commune (sans harness)
	podman build -t $(BASE_IMAGE) containers/base

build-harness: build-base ## Build un harness : make build-harness PROFILE=<name>
	podman build --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(HARNESS_IMAGE) \
	  -f containers/harness/Containerfile \
	  profiles/$(PROFILE)

build-mcp:
	podman build -t $(MCP_IMAGE) containers/mcp-remote

build-egress:
	# Image squid officielle, config montée au runtime par le launcher
	podman pull docker.io/ubuntu/squid:latest
	podman tag docker.io/ubuntu/squid:latest $(EGRESS_IMAGE)

push: ## Push vers le registry d'équipe
	podman push $(BASE_IMAGE)
	podman push $(HARNESS_IMAGE)
	podman push $(MCP_IMAGE)
	podman push $(EGRESS_IMAGE)

clean: ## Stoppe/supprime sidecars et réseau
	-podman rm -f mcp-remote egress-proxy
	-podman network rm agent-net
