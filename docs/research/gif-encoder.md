# GIF encoder: ImageIO or gifski

Researched 2026-10-14. For mia-cx/wadjet#14. Measured on an arm64 Mac (Apple Silicon), 16 GB RAM, macOS 27.2, with ffmpeg 9.0.2, gifski 1.34.0 (Homebrew), and swiftc from the installed Xcode.

## Short answer

Quality is comparable between the two encoders. ImageIO scores equal or slightly higher SSIM and 2 to 5 dB lower PSNR, produces files 10 to 30 percent smaller, and encodes at similar speed on motion content. gifski is about 2.7x faster on static content because it drops identical frames. ImageIO's downsides are memory and timing: CGImageDestination holds every added frame until finalize (about 4 MB per 960x600 frame, so a 60 s 15 fps clip means about 900 frames and 3.6 GB), and GIF delays are stored in centiseconds, so a flat 1/15 s delay rounds up to 7 cs and plays about 5 percent slow unless wadjet writes alternating 6/7 cs delays to keep cumulative time exact. gifski stayed near 200 MB RSS and kept timing correct by merging duplicate frames, but it is AGPL-3.0-or-later and needs a commercial licence for a closed or permissively licensed wadjet.

Recommendation (the lead's, from these numbers): ImageIO for v1, with exact cumulative delays and wadjet itself dropping identical consecutive frames (merging their delays) to cut memory and size. Revisit gifski only if a real Recording shows visible banding.

| Clip | Encoder | Size | Median wall | Max RSS | SSIM (All) | PSNR avg (dB) | PSNR min (dB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scroll | ImageIO | 33,013,977 B | 3.78 s | 1.23 GB | 0.9954 | 40.58 | 39.46 |
| scroll | gifski | 36,760,257 B | 3.98 s | 197 MB | 0.9838 | 42.64 | 41.24 |
| static | ImageIO | 157,300 B | 2.70 s | 1.44 GB | 0.9988 | 41.72 | 41.71 |
| static | gifski | 223,421 B | 0.98 s | 170 MB | 0.9964 | 46.66 | 46.14 |
| ui | ImageIO | 1,195,451 B | 0.93 s | 660 MB | 0.9839 | 38.66 | 31.93 |
| ui | gifski | 1,645,211 B | 0.58 s | 213 MB | 0.9834 | 42.11 | 35.63 |

Frame counts: all GIFs hold 15 fps content. ImageIO wrote 300, 300, and 90 frames. gifski deduplicated identical frames and wrote 300, 18, and 43, preserving timing through per-frame delays. Every ImageIO frame has a 0.07 s delay because GIF stores centiseconds and 1/15 s rounds up, so the 20 s clips play back in 21 s.

## Method

### Source imagery

Headless Chromium screenshots (window never brought to front). `developer.apple.com/documentation/screencapturekit` rendered as a blank dark page in `--headless=new` (near-constant luminance at every scroll depth), so the tall page and the third UI page were replaced with Wikipedia pages that render statically:

- `tall.png`: 1440x6000, `en.wikipedia.org/wiki/GIF` (scroll source).
- `page1.png`: 1440x900, `github.com/sindresorhus/KeyboardShortcuts`.
- `page2.png`: 1440x900, `gif.ski`.
- `page3.png`: 1440x900, `en.wikipedia.org/wiki/Screen_capture`.

### Source MP4s

All 1440x900, 30 fps, H.264 yuv420p, `-crf 18`:

- `scroll.mp4`: 20 s, a 1440x900 window panning top to bottom of `tall.png` via animated `crop` (constant 255 px/s).
- `static.mp4`: 20 s, one fixed 1440x900 crop of `tall.png` plus a 12x18 black box with a white border moving slowly (linear x drift plus a 10 s sine on y) via two `drawbox` filters.
- `ui.mp4`: 6 s, the three pages 2 s each joined by 0.3 s `xfade` crossfades at 1.7 s and 3.7 s, plus the moving cursor box.

### Frames

One shared extraction per clip: `ffmpeg -i clip.mp4 -vf "fps=15,scale=960:-2:flags=lanczos" <clip>/f%04d.png`, producing 300, 300, and 90 frames at 960x600. Both encoders read exactly these PNGs.

### Encoders

- ImageIO: `gif-encoder/encode-imageio.swift`, compiled `swiftc -O`. CGImageSource loads PNGs in sorted order; CGImageDestination writes a GIF with `kCGImagePropertyGIFDelayTime` = 1/15 per frame and `kCGImagePropertyGIFLoopCount` = 0. No custom quantization, matching the recipe.
- gifski: `gifski --fps 15 --quality 90 -o out.gif <clip>/f*.png`.

### Measurement

`bench.sh` runs each encoder per clip three times under `/usr/bin/time -l`. The table reports the median wall time, the median of the three max-RSS samples (all three runs were within noise anyway), and the output file size.

### Quality

ffmpeg `ssim` and `psnr` filters compare each GIF against its PNG frames, all converted to `rgb24`. The gifski input additionally gets `fps=15` first, to expand its deduplicated frames back to one frame per source PNG. The filtergraph is:

`[0:v]settb=1/15,setpts=N,format=rgb24[a];[1:v]settb=1/15,setpts=N,format=rgb24[b];[a][b]ssim` (and the same with `psnr`)

The `settb`/`setpts` pair matters: GIF frames decode with a 1/100 timebase while the image2 PNG sequence uses 1/25, so pairing by timestamp without a shared timebase compares the wrong frames. `setpts=N` alone was not sufficient; renumbering both streams onto a common `1/15` timebase is what aligns frame index to frame index.

## Licence

From gifski's own repo and site:

- gifski is licensed **AGPL-3.0-or-later**. The author (Kornel Lesiński) explicitly offers alternative commercial licences for products incompatible with the AGPL. Sources: [LICENSE](https://github.com/ImageOptim/gifski/blob/main/LICENSE), [README](https://github.com/ImageOptim/gifski/blob/main/README.md), [gif.ski/license](https://gif.ski/license.html).
- It is usable as a library with a C FFI ("supports C#, Swift, Rust, C, C++"), so a Swift app can link it directly via a C bridge; the Rust crate (`gifski` on crates.io) is built with cargo, and the CLI builds from the same repo. Source: [gif.ski](https://gif.ski/), [docs.rs/gifski](https://docs.rs/gifski/latest/src/gifski/lib.rs.html).

Implications (my reading, not legal advice):

- **Private closed-source app**: linking the gifski library makes the app a derivative work under AGPL, which requires publishing the whole app's source under AGPL when distributed. Bundling and invoking the `gifski` CLI binary is closer to "mere aggregation" and is the usual way commercial apps ship it, but it still means distributing AGPL software with its licence obligations. The clean commercial answer is the author's paid licence.
- **Open-source release under MIT or similar**: same problem. A permissively-licensed project cannot link AGPL code; the combined work must be AGPL.
- **Open-source under AGPL-3.0-or-later**: allowed outright, no commercial licence needed.
- If wadjet stays private or wants a permissive licence, options are: buy the commercial licence, ship gifski as an optional external tool the user installs, or use ImageIO.

## Caveats

- The three clips are synthetic stand-ins for real Recordings. They cover scrolling text, near-static UI with a moving cursor, and fast crossfading UI, but not camera video or game footage.
- ImageIO's PSNR trails gifski's by 2 to 5 dB per clip, with the gap concentrated in the worst frames (ui PSNR min 31.9 vs 35.6). Custom quantization would narrow this; the recipe forbade it.
- gifski `--quality 90` is not the maximum setting; higher quality increases size and encode time.
- gifski's smaller frame counts are correct behaviour: it merges identical frames and encodes timing as delays. Frame-perfect per-frame control may matter if wadjet wants exact timestamps; the loop count is still infinite.
- ImageIO peak RSS scales with frame count (~660 MB for 90 frames, ~1.4 GB for 300), because CGImageDestination retains every added CGImage until finalize. Dropping identical consecutive frames client-side shrinks both RSS and output size.
- ImageIO frame delays round to centiseconds. A flat 1/15 s delay becomes 0.07 s per frame and drifts about 5 percent slow; alternating 6 cs and 7 cs delays keeps cumulative time exact.
- Comparison crops (ImageIO left, gifski right, same 400x300 region of the middle frame): `gif-encoder/scroll-compare.png`, `gif-encoder/static-compare.png`, `gif-encoder/ui-compare.png`. Differences are visible mainly as dithering patterns on text and gradients.

## Sources

- gifski licence: [LICENSE](https://github.com/ImageOptim/gifski/blob/main/LICENSE) · [README](https://github.com/ImageOptim/gifski/blob/main/README.md) · [gif.ski license page](https://gif.ski/license.html)
- gifski library/FFI: [gif.ski](https://gif.ski/) · [docs.rs/gifski](https://docs.rs/gifski/latest/src/gifski/lib.rs.html)
- ImageIO: [CGImageDestination](https://developer.apple.com/documentation/imageio/cgimagedestination) · [GIF properties](https://developer.apple.com/documentation/imageio/gif-properties)
- Benchmark inputs: reproducible via `gif-encoder/bench.sh` and the ffmpeg commands in Method; frames, clips, and GIFs in `/tmp/wadjet-gif/` (not committed).
