#!/bin/sh
# Encodes the frames from tool/video_test.dart into the README demo video.
#   flutter test tool/video_test.dart && tool/make_video.sh
set -e
cd "$(dirname "$0")/.."
out=../../docs/video
mkdir -p "$out"
ffmpeg -y -loglevel error -framerate 30 -i build/video_frames/frame_%05d.png \
  -vf "scale=720:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 22 -movflags +faststart "$out/demo.mp4"
ffmpeg -y -loglevel error -i "$out/demo.mp4" \
  -vf "fps=12,scale=320:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a" \
  "$out/demo.gif"
ls -lh "$out"
