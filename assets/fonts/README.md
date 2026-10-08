# Windows UI font

`NotoSansSC-Compact.ttf` is a character subset of the Noto Sans SC variable font from
[Google Fonts](https://github.com/google/fonts/tree/2894aab31764f10f29c421bdfd2340d3b382d384/ofl/notosanssc),
upstream file `NotoSansSC[wght].ttf`. The modified font remains under the SIL
Open Font License in `OFL.txt`; the original copyright and license metadata
are retained. Glyph outlines and the full 100–900 weight axis are unchanged.

- Upstream commit: `2894aab31764f10f29c421bdfd2340d3b382d384`
- Upstream SHA-256: `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`
- Bundled SHA-256: `4ebc6036a0e5ad04f10a41d71141e66c58e2d8f7500c49b171c91b59a4981391`
- Size: **4,669,224 bytes**, down from 17,772,300 bytes.
- Bundled only for Windows using the asset platform filter in `pubspec.yaml`.
- Loaded before the first Flutter frame by `AppTypography.initialize`, also for
  secondary playback windows. Other platforms retain their system fonts.
- No font download, system font installation, or dependency is required at runtime.

The bundled font keeps Chinese, Latin and punctuation metrics consistent across
Windows installations. It includes continuous weights and outline glyphs without
embedded bitmap tables. All Chinese characters in the current Chinese ARB are
covered. Characters outside its coverage and emoji still use system fallbacks.

The character selection is independent of app UI copy: it includes all **6,763
GB2312 Han characters**, plus all **2,990 non-Han code points** from upstream
(Latin letters and accents, punctuation, kana, etc.), for **9,753 code points**.
The current Chinese, English and Spanish ARB strings are covered. New messages
and future UI strings use the same font whenever their characters are included.
Rare Han characters and many Traditional Chinese characters now need system
fallback. This is not a universal multilingual font: future locales need their
own script coverage and regional glyph review (for example, Traditional Chinese,
Japanese, Korean, Arabic and Thai). Fallback depends on installed fonts and may
differ visually; it cannot guarantee that every Unicode character is displayed.

The existing NSIS installer uses its default zlib compression. A compression
measurement of this font alone produces **2,974,995 bytes** (about 3 MB), down
from 11,276,551 bytes for the full font, a reduction of about **74%**. This is an
estimate, not a before/after measurement of release installers. Installed size
increases by about **4.7 MB / 4.45 MiB**, plus the small license file. Other
platforms do not include these assets. Merely restricting the weight range to
400–700 saved only about 6% of compressed size, so the compact font retains all
weights and reduces the character repertoire instead.

## Rebuilding

Use Python 3 with `fonttools==4.61.1` in a development-only environment. Download
`NotoSansSC[wght].ttf` from the pinned upstream commit, then run:

```sh
python script/build_windows_font.py /path/to/NotoSansSC\[wght\].ttf
```

The script checks the upstream hash, derives GB2312 coverage from Python's
standard codec, preserves all non-Han code points and applicable layout
features, and prints the resulting size/hash. It does not use a list extracted
from UI translations or download anything at app runtime. Keep the full source
font outside `assets/fonts/` so it cannot accidentally be packaged alongside
the compact font.
