#!/usr/bin/env python3
"""Empaqueta una carpeta USD (capa raíz + texturas referenciadas) como .usdz.

Uso: pack_usdz.py <carpeta> <capa-raiz.usdc> <salida.usdz> [--fallback <carpeta de texturas>]

Blender 5.1 deja sin empaquetar algunas texturas al exportar directamente a USDZ; por eso se exporta a carpeta,
se completan las texturas que falten desde `--fallback` (mismo nombre de archivo) y se empaqueta aquí.
Un USDZ es un ZIP sin compresión cuyos archivos empiezan alineados a 64 bytes.
"""
from __future__ import annotations

import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path


def referenced_assets(folder: Path, layer: str, fallback: Path | None) -> list[str]:
    text = subprocess.run(["xcrun", "usdcat", str(folder / layer)], capture_output=True, text=True, check=True).stdout
    found = []
    for name in sorted(set(re.findall(r"@\./([^@]+)@", text))):
        if not (folder / name).is_file() and fallback is not None and (fallback / Path(name).name).is_file():
            (folder / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(fallback / Path(name).name, folder / name)
        if (folder / name).is_file():
            found.append(name)
        else:
            sys.exit(f"falta la textura {name}")
    return found


def main() -> None:
    args = sys.argv[1:]
    fallback = None
    if "--fallback" in args:
        index = args.index("--fallback")
        fallback = Path(args[index + 1])
        del args[index:index + 2]
    folder, layer, output = Path(args[0]), args[1], Path(args[2])
    names = [layer] + referenced_assets(folder, layer, fallback)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_STORED) as archive:
        for name in names:
            data = (folder / name).read_bytes()
            info = zipfile.ZipInfo(name)
            info.compress_type = zipfile.ZIP_STORED
            offset = archive.fp.tell() + 30 + len(name.encode())
            padding = (-offset) % 64
            if padding:
                if padding < 4:
                    padding += 64
                info.extra = struct.pack("<HH", 0x1986, padding - 4) + b"\0" * (padding - 4)
            archive.writestr(info, data)
    print(f"{output.name}: {len(names)} archivos, {output.stat().st_size / 1048576:.1f} MB")


if __name__ == "__main__":
    main()
