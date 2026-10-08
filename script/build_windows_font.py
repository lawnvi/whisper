#!/usr/bin/env python3
"""Build the Windows font with fonttools==4.61.1 (development only)."""

import argparse
import hashlib
from pathlib import Path
import zlib

from fontTools import subset
from fontTools.ttLib import TTFont


SOURCE_SHA256 = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1] / "assets/fonts/NotoSansSC-Compact.ttf"
)


def is_han(codepoint):
    # Include extension and compatibility blocks when selecting the repertoire.
    return any(
        start <= codepoint <= end
        for start, end in (
            (0x3400, 0x4DBF),
            (0x4E00, 0x9FFF),
            (0xF900, 0xFAFF),
            (0x20000, 0x323AF),
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Pinned upstream variable TTF")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != SOURCE_SHA256:
        parser.error("Source font does not match the pinned upstream SHA-256")

    font = TTFont(args.source, recalcTimestamp=False)
    cmap = font.getBestCmap()
    # Keep all non-Han characters from upstream, including Latin accents,
    # punctuation and kana. Chinese coverage is independent of app UI copy.
    keep = {codepoint for codepoint in cmap if not is_han(codepoint)}
    for first in range(0xA1, 0xF8):
        for second in range(0xA1, 0xFF):
            try:
                keep.update(map(ord, bytes((first, second)).decode("gb2312")))
            except UnicodeDecodeError:
                pass
    keep.intersection_update(cmap)

    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=keep)
    subsetter.subset(font)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    font.save(args.output)

    data = args.output.read_bytes()
    print(f"Characters: {len(keep)} ({sum(map(is_han, keep))} Han)")
    print(f"Font: {len(data):,} bytes; zlib estimate: {len(zlib.compress(data, 9)):,}")
    print(f"SHA-256: {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
