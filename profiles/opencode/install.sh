#!/usr/bin/env bash
# Installe le binaire du harness DANS l'image (exécuté en root au build harness).
set -euo pipefail

# opencode (package npm officiel) — version flottante.
# PAS de --ignore-scripts : le postinstall télécharge le vrai binaire opencode
# (sinon `opencode-ai's postinstall script was not run`). Le téléchargement a
# lieu au BUILD (réseau hôte), pas au run → sans impact sur l'egress du sandbox.
npm install -g opencode-ai
