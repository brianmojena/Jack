#!/bin/zsh
# Compila la web (Svelte, en web/) y la incrusta en Sources/BuildCloudCore/WebApp.swift.
set -euo pipefail
cd "${0:A:h:h}/web"

if [[ ! -d node_modules ]]; then
  npm install --no-audit --no-fund
fi
npm run build
