#!/usr/bin/env python3
"""Prepara las ilustraciones de las cartas (dorso, jota, reina, rey y comodín) para la app.

Uso: office_cards_art.py <carpeta con back.png jack.png queen.png king.png joker.png> [salida]

Cada imagen se recorta a lo que tiene dibujado (las generadas dejan un margen transparente) y se reduce; salen como WebP con
transparencia en Resources/Office/Cards (por omisión). El dorso y el comodín son cartas enteras y se ajustan al tamaño de la
carta (512 × 768); las figuras conservan su proporción y la app las pone sobre el fondo de la carta.
"""
import sys
from pathlib import Path

from PIL import Image

CARD = (512, 768)
FIGURE_HEIGHT = 900


def trimmed(image: Image.Image) -> Image.Image:
    alpha = image.getchannel("A").point(lambda value: 255 if value > 8 else 0)
    box = alpha.getbbox()
    return image.crop(box) if box else image


def main() -> None:
    source = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "Resources/Office/Cards"
    out.mkdir(parents=True, exist_ok=True)
    for name, target, full_card in [("back", "CardBack", True), ("joker", "CardJoker", True),
                                    ("jack", "CardJack", False), ("queen", "CardQueen", False), ("king", "CardKing", False)]:
        image = trimmed(Image.open(source / f"{name}.png").convert("RGBA"))
        if full_card:
            image = image.resize(CARD, Image.LANCZOS)
        elif image.height > FIGURE_HEIGHT:
            image = image.resize((round(image.width * FIGURE_HEIGHT / image.height), FIGURE_HEIGHT), Image.LANCZOS)
        image.save(out / f"{target}.webp", "WEBP", quality=90, alpha_quality=95, method=6)
        print(f"{target}.webp {image.size} {(out / f'{target}.webp').stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
