#!/usr/bin/env bash
# Installe le binaire du harness DANS l'image (exécuté en root au build harness).
set -euo pipefail

# Claude Code (package officiel Anthropic) — version intentionnellement flottante.
npm install -g @anthropic-ai/claude-code
