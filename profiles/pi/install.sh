#!/usr/bin/env bash
# Installe le binaire du harness DANS l'image (exécuté en root au build harness).
set -euo pipefail

# pi — AI coding assistant (Mario Zechner / earendil-works). Version flottante.
# --ignore-scripts : pas de postinstall arbitraire au build (durcissement image).
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
