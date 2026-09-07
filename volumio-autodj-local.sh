#!/usr/bin/env bash
# =============================================================================
# Volumio AutoDJ / Continuous Play - local (SSH) variant
#
# For users WHO DO have SSH access to Volumio: runs directly ON Volumio
# itself, scheduled via cron or a systemd timer there (same pattern as
# volumio-smart-playlists.sh - see its "Running on a schedule" section in
# README.md). Watches Volumio's play queue via its REST API; once it's
# about to run out, picks a similar artist to the last queued track (via
# the Last.fm API), checks whether that artist is present in the local
# library (via Volumio's own MPD), and if so appends one random track by
# that artist to the end of the queue.
#
# This is the same idea as volumio-autodj.sh, but simplified for running
# locally: no "nc"-based raw MPD protocol workaround is needed here. That
# workaround exists in volumio-autodj.sh because an INDEPENDENTLY installed
# mpc client (e.g. Homebrew's on macOS) can be a newer version than
# Volumio's own bundled MPD supports, which breaks "mpc find"/"mpc search"
# outright. Running Volumio's OWN bundled mpc against its OWN bundled MPD
# (as this script does) never has that mismatch, so plain "mpc find"/
# "mpc search" work fine - no "nc" dependency needed. If you don't have
# SSH access to Volumio, use volumio-autodj.sh from a different device
# instead.
#
# Intended to be run periodically (e.g. every 1-2 minutes) via cron or a
# systemd timer - it does not loop or schedule itself. Each invocation
# does at most one queue check and, if needed, adds exactly one track.
#
# Simple repeat guard: the last HISTORY_SIZE artists that were added (or
# used as a seed) are remembered in a small history file, and skipped when
# picking a candidate, so the same artist isn't immediately re-picked over
# and over - unless NONE of the current candidates survive the guard, in
# which case it's overridden as a fallback (see step 4 below) rather than
# leaving the queue to run dry.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
# Defaults to localhost since this script is meant to run ON Volumio.
VOLUMIO_HOST="${VOLUMIO_HOST:-localhost}"
VOLUMIO_PORT="${VOLUMIO_PORT:-3000}"
MPD_HOST="${MPD_HOST:-localhost}"
MPD_PORT="${MPD_PORT:-6600}"

LASTFM_API_KEY="${LASTFM_API_KEY:?Set LASTFM_API_KEY to a free Last.fm API key (https://www.last.fm/api/account/create)}"

# How many tracks may still be left AFTER the currently playing one before
# a refill is triggered (0 = only refill once the queue is truly empty
# after the current track).
QUEUE_LOW_THRESHOLD="${QUEUE_LOW_THRESHOLD:-3}"

# How many similar artists to request from Last.fm per run - the script
# tries them in order (most similar first) until one is found locally.
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-20}"

# How many recently-used artists to remember for the repeat guard.
HISTORY_SIZE="${HISTORY_SIZE:-15}"

# How many of the most recent queue entries to consider as a seed pool -
# see step 2 below. 1 reproduces the old "always the last track" behavior.
SEED_WINDOW_SIZE="${SEED_WINDOW_SIZE:-5}"

# Same idea as SMART_PLAYLISTS_URI_PREFIXES in volumio-smart-playlists.sh -
# maps the first path segment MPD reports for a track to the prefix needed
# to build a Volumio playlist/queue "uri". Kept independent (own env var)
# so this script's config doesn't collide with the other script's.
AUTODJ_URI_PREFIXES_DEFAULT="INTERNAL|music-library/
USB|music-library/
NAS|mnt/"
URI_PREFIXES_RAW="${AUTODJ_URI_PREFIXES:-$AUTODJ_URI_PREFIXES_DEFAULT}"

# Deliberately under /data/, matching volumio-smart-playlists.sh's own
# convention (not tied to the music folder, and not assuming a
# conventional writable $HOME for whatever user this runs as via cron/
# systemd).
WORK_DIR="${AUTODJ_STATE_DIR:-/data/volumio_autodj_data}"
HISTORY_FILE="$WORK_DIR/history.txt"
DEBUG_LOG="$WORK_DIR/autodj.debug.log"

mkdir -p "$WORK_DIR"

# NOT "mv" - on some devices (seen in practice: an overlay-root Volumio
# image where /data/... files get individually tracked as their own
# overlay mount once "copied up" into the writable layer), renaming OVER
# an existing file fails with "Device or resource busy". Copy the old
# content aside, then truncate the original in place instead - avoids
# rename() entirely. This one is NOT wrapped in "|| ..." on purpose: it
# runs before log() is even defined, so there's nowhere to log a failure
# to yet - but cp/truncate failing here would previously have been just
# as fatal via "mv", so this is strictly safer than before either way.
if [[ -f "$DEBUG_LOG" ]] && (( $(stat -c%s "$DEBUG_LOG" 2>/dev/null || stat -f%z "$DEBUG_LOG" 2>/dev/null || echo 0) > 2097152 )); then
  cp -f "$DEBUG_LOG" "${DEBUG_LOG}.1" 2>/dev/null || true
  : > "$DEBUG_LOG" 2>/dev/null || true
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$DEBUG_LOG" >&2
}

for tool in curl jq mpc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' is required but not found" >&2
    exit 1
  fi
done

normalize() {
  # NOTE: the "-" must come LAST in the tr -d set below - "tr -d ' -_.'"
  # would make tr treat "space-underscore" as a RANGE (0x20-0x5F), which
  # silently deletes digits and punctuation too (e.g. "U2" -> "u",
  # "3 Doors Down" -> "doorsdown"). Placing "-" last keeps it literal.
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' _.-'
}

urlencode() {
  # NOT "-rn" combined - jq 1.4 (still the default "apt-get install jq"
  # package on Debian Jessie, which some older Volumio images are based
  # on) rejects bundled short options ("jq: Unknown option -rn") and
  # needs them passed separately.
  jq -r -n --arg v "$1" '$v | @uri'
}

# Runs a jq filter against JSON from an external API (Volumio's REST API or
# Last.fm) and prints the result, falling back to $2 (and logging the raw
# response for diagnosis) if the input can't even be parsed as JSON. A
# PLAIN "var=\"\$(... | jq ...)\"" assignment does NOT degrade gracefully
# here: if jq fails to parse its input (e.g. a transient non-JSON error
# page from Last.fm, a truncated response), the whole script dies right
# there under "set -e" - no log line, no indication why - since a failing
# command substitution used directly as an assignment's value is NOT one
# of the "set -e" exemptions. (By contrast, "done < <(... | jq ...)" used
# elsewhere in this script for building arrays is naturally safe already -
# a process substitution's own exit status doesn't trigger errexit - so
# this wrapper is only needed for single-value extractions like this.)
jq_safe() {
  local filter="$1" default="$2" json="$3" result
  if result="$(printf '%s' "$json" | jq -r "$filter" 2>>"$DEBUG_LOG")"; then
    printf '%s' "$result"
  else
    log "Warning: failed to parse a JSON response (jq filter: $filter) - falling back to '$default'. Raw response below."
    printf '%s\n' "$json" >> "$DEBUG_LOG"
    printf '%s' "$default"
  fi
}

# ---------------------------------------------------------------------------
# Repeat guard: newline-separated, normalized artist names, most recent
# last, capped at HISTORY_SIZE entries.
# ---------------------------------------------------------------------------
history_contains() {
  local norm_name="$1"
  [[ -f "$HISTORY_FILE" ]] || return 1
  grep -qxF "$norm_name" "$HISTORY_FILE"
}

history_add() {
  local norm_name="$1"
  touch "$HISTORY_FILE" 2>>"$DEBUG_LOG" || log "Warning: could not touch history file '$HISTORY_FILE'"
  # Written in ONE pass, in place (not via a temp file + "mv") - on some
  # devices (seen in practice: an overlay-root Volumio image where
  # /data/... files get individually tracked as their own overlay mount
  # once "copied up" into the writable layer), renaming OVER an existing
  # file fails with "Device or resource busy". That "mv" was an unguarded
  # command, so under "set -e" it silently killed the ENTIRE script right
  # here on every single run - invisible under cron, since cron's stderr
  # is normally redirected away, with nothing further ever getting
  # logged. Deduplicates (drop any existing occurrence of this artist so
  # it moves to the end instead of appearing twice), appends the new
  # entry, and trims to HISTORY_SIZE, all before ever touching the real
  # file - then writes the result with "cat > file" (truncate + write to
  # the existing inode, no rename() involved at all).
  { grep -vxF "$norm_name" "$HISTORY_FILE" 2>/dev/null || true; printf '%s\n' "$norm_name"; } \
    | tail -n "$HISTORY_SIZE" > "${HISTORY_FILE}.tmp" 2>>"$DEBUG_LOG"
  cat "${HISTORY_FILE}.tmp" > "$HISTORY_FILE" 2>>"$DEBUG_LOG" || log "Warning: could not write history file '$HISTORY_FILE' - repeat guard may not persist this run"
  rm -f "${HISTORY_FILE}.tmp"
  return 0
}

# ---------------------------------------------------------------------------
# 1. Check Volumio's current playback state and queue.
# ---------------------------------------------------------------------------
api_base="http://${VOLUMIO_HOST}:${VOLUMIO_PORT}/api/v1"

state_json="$(curl -sf --max-time 10 "${api_base}/getstate")" || {
  log "Could not reach Volumio's REST API at $api_base (getstate)"
  exit 1
}
status="$(jq_safe '.status // empty' '' "$state_json")"

if [[ "$status" != "play" ]]; then
  log "Volumio status is '$status' (not 'play') - nothing to do"
  exit 0
fi

queue_json="$(curl -sf --max-time 10 "${api_base}/getqueue")" || {
  log "Could not reach Volumio's REST API at $api_base (getqueue)"
  exit 1
}

position="$(jq_safe '.position // 0' '0' "$state_json")"
queue_len="$(jq_safe '.queue | length' '0' "$queue_json")"
remaining=$(( queue_len - position - 1 ))

log "Queue: $queue_len tracks, position=$position, remaining after current=$remaining (threshold=$QUEUE_LOW_THRESHOLD)"

# Position 0 with only a single track is a strong signal the user just
# started something completely new (e.g. "play" on one item, replacing
# whatever was queued before) - reset the repeat-guard history in that
# case so leftover artists from an entirely different previous listening
# session don't block otherwise-fresh candidates for this new one.
if (( position == 0 && queue_len <= 1 )) && [[ -s "$HISTORY_FILE" ]]; then
  log "Fresh queue detected (position=0, $queue_len track(s)) - resetting repeat-guard history from the previous session"
  : > "$HISTORY_FILE"
fi

if (( remaining >= QUEUE_LOW_THRESHOLD )); then
  log "Enough tracks remaining - nothing to do"
  exit 0
fi

if (( queue_len == 0 )); then
  log "Queue is empty - nothing to seed from, nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Pick a seed artist: a WEIGHTED RANDOM pick among the last
#    SEED_WINDOW_SIZE queue entries, most-recent weighted highest, rather
#    than always the very last track - keeps the similarity chain from
#    pivoting entirely on a single (possibly odd/atypical) last pick.
#    SEED_WINDOW_SIZE=1 reproduces the old "always the last track"
#    behavior exactly.
# ---------------------------------------------------------------------------
# Plain "[]" iteration (not ".queue[-N:]" slicing or ".queue[-1]" negative
# indexing) - both are jq 1.5+ features; jq 1.4 (still the default
# "apt-get install jq" package on Debian Jessie, which some Volumio images
# are still based on) doesn't support them. The "last N" window and the
# weighting are done in bash below instead.
queue_artists=()
while IFS= read -r line; do
  queue_artists+=("$line")
done < <(printf '%s' "$queue_json" | jq -r '.queue[] | .artist // empty')

total_artists=${#queue_artists[@]}
window=$SEED_WINDOW_SIZE
(( window > total_artists )) && window=$total_artists
start=$(( total_artists - window ))

# Build a weighted pool: the oldest entry in the window contributes itself
# once, the next-more-recent one twice, and so on up to the newest -
# skipping any entry without an artist tag entirely (its "slot" is simply
# not represented, rather than diluting the pool with an unusable pick).
seed_pool=()
w=1
for (( i = start; i < total_artists; i++ )); do
  [[ -z "${queue_artists[$i]}" ]] && continue
  for (( j = 0; j < w; j++ )); do
    seed_pool+=("${queue_artists[$i]}")
  done
  w=$(( w + 1 ))
done

if (( ${#seed_pool[@]} == 0 )); then
  log "None of the last $window queue entries have an artist tag - can't pick a seed, nothing to do"
  exit 0
fi

seed_artist="${seed_pool[$(( RANDOM % ${#seed_pool[@]} ))]}"

log "Seed artist (weighted pick from the last $window queue entries): $seed_artist"
norm_seed="$(normalize "$seed_artist")"
history_add "$norm_seed"

# ---------------------------------------------------------------------------
# 3. Ask Last.fm for similar artists (most similar first).
# ---------------------------------------------------------------------------
lastfm_url="http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar&artist=$(urlencode "$seed_artist")&api_key=${LASTFM_API_KEY}&format=json&limit=${CANDIDATE_LIMIT}"
lastfm_json="$(curl -sf --max-time 10 "$lastfm_url")" || {
  log "Last.fm request failed"
  exit 1
}

lastfm_error="$(jq_safe '.message // empty' '' "$lastfm_json")"
if [[ -n "$lastfm_error" ]]; then
  log "Last.fm returned an error: $lastfm_error"
  exit 1
fi

# "mapfile"/"readarray" and "declare -A" both need bash 4.0+, which isn't a
# safe assumption on Volumio's own bash across every device/image this
# might run on - plain "while read" loops and parallel arrays (see
# find_local_artist below) work on any bash version instead.
candidates=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  candidates+=("$line")
done < <(printf '%s' "$lastfm_json" | jq -r '.similarartists.artist[]?.name // empty')

if (( ${#candidates[@]} == 0 )); then
  log "Last.fm returned no similar artists for '$seed_artist'"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Try each candidate, most similar first, until one is found locally
#    (via MPD's artist list) and isn't in the repeat-guard history.
# ---------------------------------------------------------------------------
local_artists=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  local_artists+=("$line")
done < <(mpc -h "$MPD_HOST" -p "$MPD_PORT" list artist 2>>"$DEBUG_LOG")

if (( ${#local_artists[@]} == 0 )); then
  log "Could not read the local artist list from MPD ($MPD_HOST:$MPD_PORT) - is it running?"
  exit 1
fi

# Parallel arrays instead of "declare -A" - normalized name in
# local_norm[i] maps to the real, as-tagged name in local_real[i] at the
# same index.
local_norm=()
local_real=()
for a in "${local_artists[@]}"; do
  [[ -z "$a" ]] && continue
  local_norm+=("$(normalize "$a")")
  local_real+=("$a")
done

find_local_artist() {
  local target="$1" i
  for (( i = 0; i < ${#local_norm[@]}; i++ )); do
    if [[ "${local_norm[$i]}" == "$target" ]]; then
      printf '%s' "${local_real[$i]}"
      return 0
    fi
  done
  return 1
}

chosen_artist=""
for cand in "${candidates[@]}"; do
  [[ -z "$cand" ]] && continue
  norm_cand="$(normalize "$cand")"
  if history_contains "$norm_cand"; then
    log "Skipping '$cand' (recently used, repeat guard)"
    continue
  fi
  if real_match="$(find_local_artist "$norm_cand")"; then
    chosen_artist="$real_match"
    log "Match found in local library: '$cand' -> '$chosen_artist'"
    break
  fi
done

# Nothing survived the repeat guard - rather than let the queue run dry,
# fall back to whichever eligible candidate was used LEAST RECENTLY
# (earliest line in the history file) instead of simply the most similar
# one. Falling back to "most similar" would otherwise let two artists
# that mutually rank as each other's closest Last.fm match ping-pong
# forever: each run's seed becomes whichever one was just added, and its
# own most-similar fallback is the other one - bouncing between just the
# two of them instead of ever moving on. A repeated artist (picked at
# random from among their local tracks each time, same as any other pick
# - see below) is still preferable to playback simply stopping.
if [[ -z "$chosen_artist" ]]; then
  fallback_artist=""
  fallback_cand_name=""
  fallback_line=999999999
  for cand in "${candidates[@]}"; do
    [[ -z "$cand" ]] && continue
    norm_cand="$(normalize "$cand")"
    if real_match="$(find_local_artist "$norm_cand")"; then
      # "|| true": under "set -e", grep finding no match (exit 1) would
      # otherwise abort the whole script right here instead of just
      # leaving line_no empty for the "not in history at all" case below.
      line_no="$(grep -nxF "$norm_cand" "$HISTORY_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)"
      [[ -z "$line_no" ]] && line_no=0
      if (( line_no < fallback_line )); then
        fallback_line=$line_no
        fallback_artist="$real_match"
        fallback_cand_name="$cand"
      fi
    fi
  done
  if [[ -n "$fallback_artist" ]]; then
    chosen_artist="$fallback_artist"
    log "No fresh match for '$seed_artist' - falling back to least-recently-used '$fallback_cand_name' -> '$chosen_artist' rather than leaving the queue to run dry"
  fi
fi

if [[ -z "$chosen_artist" ]]; then
  log "None of the ${#candidates[@]} similar artists for '$seed_artist' are in the local library at all"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Pick one random track by that artist and build its Volumio queue uri.
# ---------------------------------------------------------------------------
# Plain "mpc find"/"mpc search" (no raw-protocol workaround needed here -
# see the header comment for why volumio-autodj.sh, the cross-machine
# variant, needs one and this local variant doesn't). "find" first (exact
# match); if that comes back empty for some other reason, fall back to
# "search" (case-insensitive substring match) and post-filter its results
# down to only files whose own artist tag normalizes to exactly the
# target artist - "search" alone would also match e.g. an unrelated
# artist whose name merely contains this one as a substring.
norm_chosen="$(normalize "$chosen_artist")"

collect_files_by_artist() {
  local mpc_cmd="$1" fpath ftitle falbum fartist
  while IFS=$'\x1f' read -r fpath ftitle falbum fartist; do
    [[ -z "$fpath" ]] && continue
    [[ "$(normalize "$fartist")" == "$norm_chosen" ]] || continue
    files+=("$fpath")
    titles+=("$ftitle")
    albums+=("$falbum")
  done < <(mpc -h "$MPD_HOST" -p "$MPD_PORT" -f $'%file%\x1f%title%\x1f%album%\x1f%artist%' "$mpc_cmd" artist "$chosen_artist" 2>>"$DEBUG_LOG")
}

files=()
titles=()
albums=()
collect_files_by_artist find

if (( ${#files[@]} == 0 )); then
  log "'mpc find artist \"$chosen_artist\"' returned nothing despite appearing in 'mpc list artist' - retrying with 'mpc search' instead"
  collect_files_by_artist search
fi

if (( ${#files[@]} == 0 )); then
  log "No files found for '$chosen_artist' via 'mpc find' or 'mpc search' - skipping"
  exit 0
fi

picked_index=$(( RANDOM % ${#files[@]} ))
picked_file="${files[$picked_index]}"
picked_title="${titles[$picked_index]}"
picked_album="${albums[$picked_index]}"

# Fall back to the bare filename if the file has no Title tag - same
# fallback the main volumio-smart-playlists.sh script uses.
if [[ -z "$picked_title" ]]; then
  picked_title="${picked_file##*/}"
fi

# Volumio's addToQueue wants a "trackType" (the file format, e.g. "flac"),
# derived here from the file extension rather than queried separately.
picked_track_type="$(printf '%s' "${picked_file##*.}" | tr '[:upper:]' '[:lower:]')"

uri=""
label="${picked_file%%/*}"
while IFS='|' read -r lbl pfx; do
  [[ -z "$lbl" ]] && continue
  if [[ "$lbl" == "$label" ]]; then
    uri="${pfx}${picked_file}"
    break
  fi
done <<< "$URI_PREFIXES_RAW"

if [[ -z "$uri" ]]; then
  log "No configured uri prefix for source label '$label' (path: $picked_file) - set AUTODJ_URI_PREFIXES; skipping"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Append it to Volumio's queue.
# ---------------------------------------------------------------------------
# NOTE: addToQueue is NOT one of the simple "?cmd=..." GET commands (those
# only cover playback control like play/pause/next/volume) - it is its own
# POST endpoint that takes a JSON item, and Volumio requires at least
# uri/service/title/type/trackType on it (a bare uri, or the ?cmd= form,
# gets rejected with {"Error":"command not recognized"}).
add_payload="$(jq -n \
  --arg uri "$uri" \
  --arg title "$picked_title" \
  --arg artist "$chosen_artist" \
  --arg album "$picked_album" \
  --arg trackType "$picked_track_type" \
  '{uri: $uri, service: "mpd", title: $title, artist: $artist, album: $album, type: "song", trackType: $trackType}')"

add_response="$(curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' -d "$add_payload" "${api_base}/addToQueue")" || {
  log "addToQueue POST request failed for uri '$uri'"
  exit 1
}

log "Added '$picked_file' (artist: $chosen_artist) to the queue - response: $add_response"
history_add "$(normalize "$chosen_artist")"
