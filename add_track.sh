#!/bin/bash

# === CONFIG ===
MUSIC_DIR="./sound/music"
OUTPUT="./configs/musiclist.txt"

# === UTILITY ===
next_track_number() {
    local last=$(ls "$MUSIC_DIR"/track*.wav 2>/dev/null | sed -E 's/.*track([0-9]+)\.wav/\1/' | sort -n | tail -n 1)
    echo $((last + 1))
}

extract_duration() {
    local file="$1"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" | awk '{print int($1)}'
}

extract_title() {
    local info_file="$1"
    local raw_title
    raw_title=$(jq -r '.title' "$info_file" | sed 's/[“”"]/"/g' | sed 's/[[:space:]]*$//' | tr -d '\n')

    if [[ "$raw_title" =~ ^(.+)[[:space:]]*[-–][[:space:]]*(.+)$ ]]; then
        local artist="${BASH_REMATCH[1]}"
        local track="${BASH_REMATCH[2]}"
        echo "$artist – $track"
    else
        echo "$raw_title"
    fi
}

# === CHECKS ===
if ! command -v yt-dlp &>/dev/null || ! command -v ffprobe &>/dev/null || ! command -v jq &>/dev/null || ! command -v ffmpeg &>/dev/null; then
    echo "Missing dependency. Please install yt-dlp, ffmpeg, and jq." >&2
    exit 1
fi

# === INPUT ===
URL="$1"
[ -z "$URL" ] && echo "Usage: $0 <YouTube URL>" && exit 1

mkdir -p "$MUSIC_DIR"
mkdir -p "$(dirname "$OUTPUT")"

# === GET INFO ===
echo "[+] Fetching video info..."
INFO_FILE=$(mktemp)
yt-dlp --extractor-args "youtube:player_client=android" --dump-json "$URL" > "$INFO_FILE" || {
    echo "❌ Failed to fetch metadata"
    rm "$INFO_FILE"
    exit 1
}

TITLE=$(extract_title "$INFO_FILE")
TRACK_NUM=$(next_track_number)
OUT_NAME="track${TRACK_NUM}.wav"
OUT_PATH="$MUSIC_DIR/$OUT_NAME"

# === DOWNLOAD + CONVERT ===
echo "[+] Downloading and converting with Android workaround..."
yt-dlp \
  --extractor-args "youtube:player_client=android" \
  -x --audio-format wav --audio-quality 0 \
  -o "$OUT_PATH" \
  "$URL" || { echo "❌ Download failed"; rm "$INFO_FILE"; exit 1; }

# === EXTRACT DURATION ===
DURATION=$(extract_duration "$OUT_PATH")
if [[ -z "$DURATION" || "$DURATION" -le 0 ]]; then
    echo "❌ Could not determine duration"
    rm "$INFO_FILE"
    exit 1
fi

# === UPDATE MUSIC LIST ===
echo "$OUT_NAME $DURATION \"$TITLE\"" >> "$OUTPUT"
echo "[✓] Added: $TITLE as $OUT_NAME ($DURATION sec)"
rm "$INFO_FILE"
