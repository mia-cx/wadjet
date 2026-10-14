#!/bin/bash
# bench.sh - GIF encoder benchmark for wadjet issue #14.
# Encodes /tmp/wadjet-gif/<clip>/f*.png with ImageIO and gifski,
# 3 runs each, reports wall time and max RSS via /usr/bin/time -l.
# Usage: bash bench.sh
set -u

BASE=/tmp/wadjet-gif
CLIPS="scroll static ui"
SWIFT_BIN="$BASE/encode-imageio"

if [ ! -x "$SWIFT_BIN" ]; then
    swiftc -O -o "$SWIFT_BIN" "$(dirname "$0")/encode-imageio.swift" || exit 1
fi

for clip in $CLIPS; do
    for enc in imageio gifski; do
        for run in 1 2 3; do
            out="$BASE/${clip}-${enc}.gif"
            log="$BASE/time-${clip}-${enc}-${run}.txt"
            if [ "$enc" = imageio ]; then
                /usr/bin/time -l "$SWIFT_BIN" "$BASE/$clip" "$out" 15 > /dev/null 2> "$log"
            else
                /usr/bin/time -l gifski --fps 15 --quality 90 -o "$out" "$BASE/$clip"/f*.png > /dev/null 2> "$log"
            fi
            wall=$(grep -E '^ *[0-9.]+ +real' "$log" | awk '{print $1}')
            rss=$(grep 'maximum resident set size' "$log" | awk '{print $1}')
            size=$(stat -f %z "$out")
            echo "$clip $enc run$run wall=${wall}s rss=${rss}B size=${size}B"
        done
    done
done

# Quality: compare each GIF against its source PNGs.
# gifski gets fps=15 first to expand deduplicated frames.
# settb/setpts onto a shared 1/15 timebase aligns frame index to frame index;
# GIF uses tb 1/100, image2 uses 1/25, so setpts=N alone pairs wrong frames.
for clip in $CLIPS; do
    for enc in imageio gifski; do
        gif="$BASE/${clip}-${enc}.gif"
        extra=""
        [ "$enc" = gifski ] && extra="fps=15,"
        ffmpeg -i "$gif" -framerate 15 -i "$BASE/$clip/f%04d.png" \
            -lavfi "[0:v]${extra}settb=1/15,setpts=N,format=rgb24[a];[1:v]settb=1/15,setpts=N,format=rgb24[b];[a][b]ssim" \
            -f null - 2>&1 | grep 'All:' | tail -1
        ffmpeg -i "$gif" -framerate 15 -i "$BASE/$clip/f%04d.png" \
            -lavfi "[0:v]${extra}settb=1/15,setpts=N,format=rgb24[a];[1:v]settb=1/15,setpts=N,format=rgb24[b];[a][b]psnr" \
            -f null - 2>&1 | grep 'average:' | tail -1
    done
done
