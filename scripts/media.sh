#!/usr/bin/env bash
# The README's screenshots and GIFs, made again: each scene played in a GUI
# Emacs of its own (emacs -Q, its own temp folders: your Emacs and its
# settings aren't touched), captured with macOS's screencapture into
# docs/images/; the GIFs made from their frames with ffmpeg. See
# scripts/media/media.el for the scenes.
#
#   scripts/media.sh                    every scene
#   scripts/media.sh figures asking     those named (release, figures, content, asking)
#
# Needs macOS (screencapture), ffmpeg, and the dependencies in .deps/ (make
# deps; make media-deps adds doom-themes, the screenshots' theme). The
# terminal running it needs the Screen Recording permission (System Settings
# > Privacy & Security > Screen & System Audio Recording); macOS asks for it
# the first time. Mermaid's CLI (mmdc) draws the content scene's diagram.
#
# EMACS_GUI (default: /Applications/Emacs.app's, else emacs) runs it;
# MEDIA_OUT (default: docs/images/) gets the images.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${MEDIA_OUT:-$ROOT/docs/images}
DEPS=${DEPS_DIR:-$ROOT/.deps}
if [ -z "${EMACS_GUI:-}" ]; then
  EMACS_GUI=/Applications/Emacs.app/Contents/MacOS/Emacs
  [ -x "$EMACS_GUI" ] || EMACS_GUI=emacs
fi

case "${1:-}" in
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac
[ "$(uname)" = Darwin ] || { echo "media.sh: macOS only (screencapture)" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "media.sh: needs ffmpeg (brew install ffmpeg)" >&2; exit 2; }
[ -d "$DEPS/agent-shell" ] || { echo "media.sh: no dependencies in $DEPS: make deps" >&2; exit 2; }

load_path=(-L "$ROOT")
for dep in "$DEPS"/*/; do load_path+=(-L "${dep%/}"); done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-ui-media.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$OUT"

status=0
MEDIA_SCENES="$*" MEDIA_OUT="$OUT/" MEDIA_TMP="$tmp" \
  "$EMACS_GUI" -Q --init-directory="$tmp/home" "${load_path[@]}" \
  -l "$ROOT/scripts/media/media.el" -f media-run >"$tmp/log" 2>&1 || status=$?
grep '^media: ' "$tmp/log" | sed 's/^media: /  /' || true
if [ "$status" -ne 0 ]; then
  echo "media.sh: Emacs failed (exit $status); its log:" >&2
  grep -v '^media: ' "$tmp/log" | tail -20 >&2
  exit 1
fi

# The GIFs: their frames at 4 a second, 960 px wide, the last frame held.
for frames in "$OUT"/*-frames; do
  [ -d "$frames" ] || continue
  name=$(basename "$frames" -frames)
  ffmpeg -loglevel error -y -framerate 4 -i "$frames/%04d.png" -vf \
    "scale=960:-1:flags=lanczos,tpad=stop_mode=clone:stop_duration=2.5,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$OUT/$name.gif"
  rm -rf "$frames"
  echo "  $OUT/$name.gif"
done
