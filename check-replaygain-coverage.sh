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
#
# No external tools required at all (no mpc, no nc) - talks to MPD
# directly over its own plain-text protocol via bash's built-in /dev/tcp,
# for both listing the library and reading each file's comments. Started
# out using "mpc listallinfo" for the library listing, but mpc 0.26 (a
# real device this was tested against) doesn't expose "listallinfo" as a
# subcommand at all, even though it's a perfectly normal native MPD
# command - going straight to the protocol sidesteps depending on any
# particular mpc version's CLI surface.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

MPD_HOST="${MPD_HOST:-localhost}"
MPD_PORT="${MPD_PORT:-6600}"
OUTPUT_TSV="${OUTPUT_TSV:-$PWD/replaygain_coverage.tsv}"

mpd_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# No external "nc" dependency - confirmed missing on at least one real
# Volumio device this was tested against, unlike mpc which Volumio always
# ships (it's how Volumio itself talks to its own MPD). Bash's own
# /dev/tcp pseudo-device (built into bash - nothing extra to install)
# is enough for MPD's plain-text protocol, unlike the cross-machine
# volumio-autodj.sh where "nc" specifically sidesteps an mpc/libmpdclient
# version mismatch that doesn't apply here (this always runs against
# Volumio's own mpc talking to its own MPD).
#
# A single flaky connection must not abort a scan that might be thousands
# of files deep - every step here is defensively "|| return 1", treated
# the same as "no comments found" by the caller, same reasoning as
# jq_safe() in the AutoDJ scripts.
#
# "{ exec 3<>...; } 2>/dev/null" (a brace GROUP, not a subshell) rather
# than "exec 3<>... 2>/dev/null" directly - confirmed bash prints its own
# "connect: Connection refused" diagnostic straight to the real stderr
# regardless of a redirect placed on the failing exec statement itself
# (the redirection never "takes" since it's part of what's failing); a
# brace group's redirection applies to everything inside it without that
# timing problem, while - unlike a real subshell "( ... )" - still runs in
# THIS shell, so fd 3 stays open afterward for the rest of the function.
mpd_raw_query() {
  local cmd="$1" reply=""
  { exec 3<>"/dev/tcp/$MPD_HOST/$MPD_PORT"; } 2>/dev/null || return 1
  printf '%s\nclose\n' "$cmd" >&3 2>/dev/null || { exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null; return 1; }
  reply="$(cat <&3 2>/dev/null)"
  exec 3<&- 2>/dev/null
  exec 3>&- 2>/dev/null
  printf '%s' "$reply"
}

echo "Enumerating library via 'lsinfo' + per-directory 'listallinfo' ..." >&2

# Sent via mpd_raw_query, NOT "mpc listallinfo" - confirmed on the user's
# real device that mpc 0.26 doesn't expose "listallinfo" as a subcommand
# at all ("unknown command"), even though it's a perfectly normal native
# MPD protocol command. Same lesson as dropping "nc" above: go straight to
# the protocol instead of assuming a particular mpc version's CLI surface.
#
# A SINGLE "listallinfo" call for the whole library (no path argument)
# was tried first and confirmed, on a real device, to silently under-count
# a large library (12354 of 27331 actual tracks) - no error, just a
# truncated response. A flat split into one "listallinfo <dir>" call per
# TOP-LEVEL directory was tried next, but doesn't help when nearly
# everything lives under a single one of those (also confirmed on a real
# device) - that one directory's own listallinfo call is just as likely to
# get truncated in turn. scan_dir() below instead recurses ADAPTIVELY: on
# a truncated response it re-lists that same directory's own
# subdirectories (via "lsinfo <dir>") and retries each of THOSE
# separately, splitting deeper and deeper whenever needed regardless of
# how unevenly the library happens to be laid out, until every individual
# chunk actually completes - or, at a leaf directory with no
# subdirectories left to split into, falls back to the partial chunk with
# a warning naming exactly which directory is affected.
top_level_dirs=()
lsinfo_reply="$(mpd_raw_query "lsinfo")" || {
  echo "Error: could not reach MPD at $MPD_HOST:$MPD_PORT" >&2
  exit 1
}
while IFS= read -r line; do
  case "$line" in
    "directory: "*) top_level_dirs+=("${line#directory: }") ;;
  esac
done <<< "$lsinfo_reply"

if (( ${#top_level_dirs[@]} == 0 )); then
  echo "No top-level directories found via 'lsinfo' - nothing to check." >&2
  exit 0
fi

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

parse_listallinfo_chunk() {
  local chunk="$1"
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
  done <<< "$chunk"
}

# Recursive: on a truncated "listallinfo <dir>" response, splits into
# <dir>'s own subdirectories and retries each separately (see the comment
# above) instead of accepting a partial chunk, as many levels deep as it
# takes. MAX_SCAN_DEPTH bounds the recursion - real folder nesting never
# gets remotely close to it, it's just insurance against a pathological
# structure (or a misbehaving MPD reply) causing an unbounded loop instead
# of a bounded, reported failure.
MAX_SCAN_DEPTH=12

scan_dir() {
  local dir="$1" depth="${2:-0}" chunk last_line lsinfo_chunk subdirs=() sub line

  if (( depth > MAX_SCAN_DEPTH )); then
    echo "Warning: '$dir' is more than $MAX_SCAN_DEPTH levels deep into repeated splitting - giving up on it rather than recursing indefinitely. Track count for it may be incomplete." >&2
    return
  fi

  echo "  scanning '$dir' ..." >&2
  chunk="$(mpd_raw_query "listallinfo $(mpd_quote "$dir")")" || {
    echo "Warning: could not reach MPD while listing '$dir' - skipping" >&2
    return
  }

  last_line="$(printf '%s' "$chunk" | tail -n 1)"
  if [[ "$last_line" == "OK" ]]; then
    parse_listallinfo_chunk "$chunk"
    return
  fi

  lsinfo_chunk="$(mpd_raw_query "lsinfo $(mpd_quote "$dir")")" || lsinfo_chunk=""
  while IFS= read -r line; do
    case "$line" in
      "directory: "*) subdirs+=("${line#directory: }") ;;
    esac
  done <<< "$lsinfo_chunk"

  if (( ${#subdirs[@]} > 0 )); then
    echo "  '$dir' response looked truncated - splitting into ${#subdirs[@]} subdirectory/subdirectories..." >&2
    for sub in "${subdirs[@]}"; do
      scan_dir "$sub" $(( depth + 1 ))
    done
  else
    echo "Warning: '$dir' response did not end with 'OK' and has no subdirectories left to split into - track count for it may be incomplete." >&2
    parse_listallinfo_chunk "$chunk"
  fi
}

for dir in "${top_level_dirs[@]}"; do
  scan_dir "$dir"
done
flush_current

total=${#files[@]}
if (( total == 0 )); then
  echo "No tracks found via 'listallinfo' - nothing to check." >&2
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

  comments="$(mpd_raw_query "readcomments $(mpd_quote "$f")")" || comments=""

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
