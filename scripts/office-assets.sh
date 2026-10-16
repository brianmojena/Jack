#!/bin/zsh
# Empaqueta como USDZ lo que `export_all()` dejó en OFFICE_STAGING y lo valida con usdchecker.
# Uso: scripts/office-assets.sh [carpeta de exportación]   (por omisión /tmp/office_export)
set -euo pipefail
cd "${0:A:h:h}"
staging="${1:-${OFFICE_STAGING:-/tmp/office_export}}"
runtime="Resources/Office/Runtime"
mkdir -p "$runtime"
for name in OfficeRoom REMY CH31 GIRL; do
  python3 scripts/pack_usdz.py "$staging/$name" "$name.usdc" "$runtime/$name.usdz" --fallback "$staging/source_textures"
  xcrun usdchecker "$runtime/$name.usdz" 2>&1 | grep -E "Error|Failed|Success" | head -3
done
du -sh "$runtime"
