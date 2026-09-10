#!/usr/bin/env bash
# =============================================================================
# ReplayGain tag coverage check
#
# One-off diagnostic - NOT run periodically like the AutoDJ scripts. Scans
# the entire MPD library and reports how many tracks (and which albums)
# carry REPLAYGAIN_TRACK_GAIN / REPLAYGAIN_ALBUM_GAIN tags versus none at
# all. Useful to gauge how much effect AUTO_REPLAYGAIN (see
# volumio-autodj.sh / volumio-autodj-local.sh) will actually have: MPD's
# ReplayGain only adjusts volume for tracks that carry these tags - it has
# no effect on the rest.
#
# Run directly on Volumio via SSH (MPD_HOST defaults to localhost); point
# it at a different host with MPD_HOST/MPD_PORT if you'd rather run it
# from elsewhere on the network.
#
# Why this has to check file-by-file: MPD's database/tag cache does NOT
# index ReplayGain tags - they're not part of the standard "browsable" tag
# set used by "mpc find"/"search"/"list" (which only cover Artist, Album,
# Title, Genre, Date, etc.). The only way to see them is MPD's
# "readcomments <uri>" command, which reads a single file's raw metadata
# comments directly - one MPD round-trip per file, no bulk query exists.
# For a large library this can take a while; progress is printed every
# 200 tracks.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

MPD_HOST="${MPD_HOST:-localhost}"
MPD_PORT="${MPD_PORT:-6600}"
OUTPUT_TSV="${OUTPUT_TSV:-$PWD/replaygain_coverage.tsv}"

for tool in mpc nc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' is required but not found" >&2
    exit 1
  fi
done

mpd_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# "|| true": a single flaky connection must not abort a scan that might be
# thousands of files deep - treated the same as "no comments found" below,
# same defensive reasoning as jq_safe() in the AutoDJ scripts.
mpd_raw_query() {
  printf '%s\nclose\n' "$1" | nc -w 10 "$MPD_HOST" "$MPD_PORT" 2>/dev/null || true
}

echo "Enumerating library via 'mpc listallinfo' ..." >&2

files=()
artists=()
albums=()
titles=()

cur_file="" cur_artist="" cur_album="" cur_title=""
flush_current() {
  if [[ -n "$cur_file" ]]; then
    files+=("$cur_file")
    artists+=("$cur_artist")
    albums+=("$cur_album")
    titles+=("$cur_title")
  fi
}

while IFS= read -r line; do
  case "$line" in
    "file: "*)
      flush_current
      cur_file="${line#file: }"
      cur_artist=""
      cur_album=""
      cur_title=""
      ;;
    "Artist: "*) cur_artist="${line#Artist: }" ;;
    "Album: "*)  cur_album="${line#Album: }" ;;
    "Title: "*)  cur_title="${line#Title: }" ;;
  esac
done < <(mpc -h "$MPD_HOST" -p "$MPD_PORT" listallinfo)
flush_current

total=${#files[@]}
if (( total == 0 )); then
  echo "No tracks found via 'mpc listallinfo' - nothing to check." >&2
  exit 0
fi

echo "Found $total tracks. Checking ReplayGain tags one file at a time (this can take a while)..." >&2

with_track_gain=0
with_album_gain=0
without_any=0

printf 'file\tartist\talbum\ttitle\thas_track_gain\thas_album_gain\n' > "$OUTPUT_TSV"

# Parallel arrays instead of "declare -A" (needs bash 4.0+, not a safe
# assumption on every device this might run on) - same convention as the
# AutoDJ scripts' local_norm/local_real arrays.
album_keys=()
album_totals=()
album_gains=()

# Sets $ALBUM_IDX rather than printing the index for the caller to capture
# via "$(...)" - command substitution runs the function in a SUBSHELL, so
# the album_keys/album_totals/album_gains appends below would only affect
# the subshell's copy of those arrays and never reach the caller at all.
find_or_add_album() {
  local key="$1" i
  for (( i = 0; i < ${#album_keys[@]}; i++ )); do
    if [[ "${album_keys[$i]}" == "$key" ]]; then
      ALBUM_IDX=$i
      return 0
    fi
  done
  album_keys+=("$key")
  album_totals+=(0)
  album_gains+=(0)
  ALBUM_IDX=$(( ${#album_keys[@]} - 1 ))
}

for (( i = 0; i < total; i++ )); do
  f="${files[$i]}"
  a="${artists[$i]}"
  al="${albums[$i]}"
  t="${titles[$i]}"

  comments="$(mpd_raw_query "readcomments $(mpd_quote "$f")")"

  has_track=0
  has_album=0
  if printf '%s' "$comments" | grep -qi '^replaygain_track_gain:'; then
    has_track=1
  fi
  if printf '%s' "$comments" | grep -qi '^replaygain_album_gain:'; then
    has_album=1
  fi

  (( has_track )) && with_track_gain=$(( with_track_gain + 1 ))
  (( has_album )) && with_album_gain=$(( with_album_gain + 1 ))
  (( has_track == 0 && has_album == 0 )) && without_any=$(( without_any + 1 ))

  album_key="${al:-<no album tag>}"
  find_or_add_album "$album_key"
  idx="$ALBUM_IDX"
  album_totals[$idx]=$(( album_totals[$idx] + 1 ))
  if (( has_track || has_album )); then
    album_gains[$idx]=$(( album_gains[$idx] + 1 ))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$a" "$al" "$t" "$has_track" "$has_album" >> "$OUTPUT_TSV"

  if (( (i + 1) % 200 == 0 )); then
    echo "  processed $(( i + 1 ))/$total..." >&2
  fi
done

echo "" >&2
echo "=== ReplayGain tag coverage ===" >&2
echo "Total tracks scanned: $total" >&2
printf '  With REPLAYGAIN_TRACK_GAIN: %d (%d%%)\n' "$with_track_gain" "$(( with_track_gain * 100 / total ))" >&2
printf '  With REPLAYGAIN_ALBUM_GAIN: %d (%d%%)\n' "$with_album_gain" "$(( with_album_gain * 100 / total ))" >&2
printf '  Without ANY replaygain tag: %d (%d%%)\n' "$without_any" "$(( without_any * 100 / total ))" >&2

echo "" >&2
echo "=== Albums with NO ReplayGain tags at all ===" >&2
no_gain_albums=0
for (( i = 0; i < ${#album_keys[@]}; i++ )); do
  if (( album_gains[i] == 0 )); then
    printf '  %s (%d tracks)\n' "${album_keys[$i]}" "${album_totals[$i]}" >&2
    no_gain_albums=$(( no_gain_albums + 1 ))
  fi
done
echo "  ($no_gain_albums of ${#album_keys[@]} albums)" >&2

echo "" >&2
echo "Full per-file results: $OUTPUT_TSV" >&2
