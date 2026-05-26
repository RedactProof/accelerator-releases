"""
Generate NSIS installer assets from the brand logo.

Outputs in this folder:
  - app.ico            multi-size (16/32/48/64/128/256) — installer + Add/Remove Programs
  - welcome.bmp        164x314 BMP — MUI welcome/finish page
  - header.bmp         150x57  BMP — MUI inner-page header

Run once and commit the outputs. NSIS reads the static files; it doesn't run Python.

Usage: python generate.py
"""
from pathlib import Path
from PIL import Image

HERE = Path(__file__).parent
SRC_LOGO = HERE / "logo-source.png"
BG = (255, 255, 255)  # white background, matches NSIS MUI default


def to_rgba(img: Image.Image) -> Image.Image:
    return img.convert("RGBA") if img.mode != "RGBA" else img


def make_ico(src: Path, dst: Path) -> None:
    img = to_rgba(Image.open(src))
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    img.save(dst, format="ICO", sizes=sizes)


def paste_centered(canvas: Image.Image, fg: Image.Image, max_frac: float = 0.7) -> Image.Image:
    cw, ch = canvas.size
    target = int(min(cw, ch) * max_frac)
    fg_resized = fg.copy()
    fg_resized.thumbnail((target, target), Image.LANCZOS)
    fw, fh = fg_resized.size
    canvas.paste(fg_resized, ((cw - fw) // 2, (ch - fh) // 2), fg_resized if fg_resized.mode == "RGBA" else None)
    return canvas


def make_bmp(src: Path, dst: Path, size: tuple[int, int], max_frac: float) -> None:
    fg = to_rgba(Image.open(src))
    canvas = Image.new("RGB", size, BG)
    paste_centered(canvas, fg, max_frac)
    canvas.save(dst, format="BMP")


def main() -> None:
    if not SRC_LOGO.exists():
        raise SystemExit(f"Source logo not found: {SRC_LOGO}")

    make_ico(SRC_LOGO, HERE / "app.ico")
    make_bmp(SRC_LOGO, HERE / "welcome.bmp", (164, 314), 0.6)
    make_bmp(SRC_LOGO, HERE / "header.bmp", (150, 57), 0.85)

    print("Wrote app.ico, welcome.bmp, header.bmp in", HERE)


if __name__ == "__main__":
    main()
