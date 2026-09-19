#!/usr/bin/env bash
# =============================================================================
# Volumio AutoDJ / Continuous Play
#
# Runs on a SEPARATE device on the same network as Volumio (NOT on Volumio
# itself - no SSH access to Volumio required). Watches Volumio's play queue
# via its REST API; once it's about to run out, picks a similar artist to
# the last queued track (via the Last.fm API), checks whether that artist
# is present in the local library (via MPD, queried over the network), and
# if so appends one random track by that artist to the end of the queue.
#
# Intended to be run periodically (e.g. every 1-2 minutes) via cron or a
# systemd timer ON THE DEVICE THIS SCRIPT RUNS ON - it does not loop or
# schedule itself. Each invocation does at most one queue check and, if
# needed, adds exactly one track.
#
# Repeat guard, split in two: the last ARTIST_HISTORY_SIZE artists that
# were added (or used as a seed) are skipped when picking a candidate, and
# separately, the last TRACK_HISTORY_SIZE tracks that were actually added
# are skipped when picking WHICH track of a chosen artist to add. The same
# artist coming up again isn't really a problem; hearing the exact same
# song again soon is - so the track guard is normally set larger than the
# artist one.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
VOLUMIO_HOST="${VOLUMIO_HOST:?Set VOLUMIO_HOST to the Volumio devices IP/hostname}"
VOLUMIO_PORT="${VOLUMIO_PORT:-3000}"
api_base="http://${VOLUMIO_HOST}:${VOLUMIO_PORT}/api/v1"

# MPD is queried directly (not through Volumio's REST API, which has no
# "does this artist exist locally / list their tracks" endpoint) to check
# whether a similar-artist candidate is actually in your library and to
# pick a track. Defaults to the same host as Volumio, since Volumio's own
# MPD is normally what you want. Requires MPD to be reachable on the
# network (not just localhost) - check `grep bind_to_address /etc/mpd.conf`
# on Volumio if this fails to connect; that one setting still needs to be
# changed on Volumio itself, but that's a one-time config edit, not what
# this script (or its scheduling) needs SSH for on an ongoing basis.
MPD_HOST="${MPD_HOST:-$VOLUMIO_HOST}"
MPD_PORT="${MPD_PORT:-6600}"

# ---------------------------------------------------------------------------
# Mode: normal (default) one-shot queue check, or "--watch-boundary" - a
# lightweight, frequently-run companion loop that ONLY watches for playback
# reaching the AutoDJ mixed-content boundary and syncs replay gain/crossfade
# at that moment (see boundary_watch_tick() below). Split out from the main
# queue-refill logic (still run on its own, much longer, QUEUE_LOW_THRESHOLD-
# driven interval via cron/systemd) because reacting to a track change
# promptly needs a short poll interval, while refilling the queue doesn't -
# running the full heavy logic (Last.fm calls, mpc library scans) that often
# would be wasteful. See "Avoiding a mid-song volume jump" in README.md.
# ---------------------------------------------------------------------------
WATCH_BOUNDARY_ONLY=0
[[ "${1:-}" == "--watch-boundary" ]] && WATCH_BOUNDARY_ONLY=1

# Not needed in watch mode - only the main queue-refill logic below ever
# talks to Last.fm.
if (( WATCH_BOUNDARY_ONLY )); then
  LASTFM_API_KEY="${LASTFM_API_KEY:-}"
else
  LASTFM_API_KEY="${LASTFM_API_KEY:?Set LASTFM_API_KEY to a free Last.fm API key (https://www.last.fm/api/account/create)}"
fi

# How many tracks may still be left AFTER the currently playing one before
# a refill is triggered (0 = only refill once the queue is truly empty
# after the current track).
QUEUE_LOW_THRESHOLD="${QUEUE_LOW_THRESHOLD:-3}"

# How many similar artists to request from Last.fm per run - the script
# tries them in order (most similar first) until one is found locally.
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-20}"

# Repeat guard, split in two - see the header comment above.
ARTIST_HISTORY_SIZE="${ARTIST_HISTORY_SIZE:-4}"
TRACK_HISTORY_SIZE="${TRACK_HISTORY_SIZE:-15}"

# How many of the most recent queue entries to consider as a seed pool -
# see step 2 below. 1 reproduces the old "always the last track" behavior.
SEED_WINDOW_SIZE="${SEED_WINDOW_SIZE:-5}"

# When the initial seed's Last.fm candidates are all blocked by the repeat
# guard (or not found locally), retry with up to this many different seed
# artists picked at random from the queue before falling back to the
# least-recently-used candidate - see step 4b below.
MAX_SEED_RETRIES="${MAX_SEED_RETRIES:-2}"

# When "on", the script also manages MPD's volume normalization (replay
# gain) automatically: switches it to "track" mode once AutoDJ actually
# starts mixing a new artist into the queue, and back to "off" at the next
# fresh-queue reset (see step 1 below and "Volume normalization" in
# README.md). Off by default - most users manage this setting themselves
# and don't expect a background script to touch a global playback option.
AUTO_REPLAYGAIN="$(printf '%s' "${AUTO_REPLAYGAIN:-off}" | tr '[:upper:]' '[:lower:]')"

# Same idea as AUTO_REPLAYGAIN above, same on/off management (see step 1
# and the successful-add step below) - "off" (default) leaves MPD's
# crossfade setting alone, any whole number of seconds enables it with
# that duration once AutoDJ starts mixing, back to 0 at the next
# fresh-queue reset.
AUTO_CROSSFADE="$(printf '%s' "${AUTO_CROSSFADE:-off}" | tr '[:upper:]' '[:lower:]')"
if [[ "$AUTO_CROSSFADE" != "off" ]] && ! [[ "$AUTO_CROSSFADE" =~ ^[0-9]+$ ]]; then
  echo "Error: AUTO_CROSSFADE must be 'off' or a whole number of seconds, got '$AUTO_CROSSFADE'" >&2
  exit 1
fi

# Same idea as SMART_PLAYLISTS_URI_PREFIXES in volumio-smart-playlists.sh -
# maps the first path segment MPD reports for a track to the prefix needed
# to build a Volumio playlist/queue "uri". Kept independent (own env var)
# since this script runs on a different machine and has no access to the
# other script's config.
AUTODJ_URI_PREFIXES_DEFAULT="INTERNAL|music-library/
USB|music-library/
NAS|mnt/"
URI_PREFIXES_RAW="${AUTODJ_URI_PREFIXES:-$AUTODJ_URI_PREFIXES_DEFAULT}"

STATE_DIR="${AUTODJ_STATE_DIR:-$HOME/.volumio-autodj}"
ARTIST_HISTORY_FILE="$STATE_DIR/artist_history.txt"
TRACK_HISTORY_FILE="$STATE_DIR/track_history.txt"
REPLAYGAIN_STATE_FILE="$STATE_DIR/replaygain_state.txt"
CROSSFADE_STATE_FILE="$STATE_DIR/crossfade_state.txt"
MIXED_BOUNDARY_FILE="$STATE_DIR/mixed_boundary.txt"
LAST_POSITION_FILE="$STATE_DIR/last_position.txt"
WATCH_LAST_POSITION_FILE="$STATE_DIR/watch_last_position.txt"
DEBUG_LOG="$STATE_DIR/autodj.debug.log"

mkdir -p "$STATE_DIR"

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

# In "--watch-boundary" mode the script polls Volumio's REST API (curl/jq)
# for the queue position, plus MPD directly via mpd_raw_query() ("nc") for
# crossfade - "mpc" (needed only by the full queue-refill logic) is the one
# tool NOT required just to run that mode. Plain space-separated string, not
# a bash array, iterated below - "${arr[@]}" on an EMPTY array raises
# "unbound variable" under "set -u" on bash older than 4.4 (fixed there, but
# not a safe assumption across every device this might run on; same
# reasoning as this script avoiding "declare -A"/"mapfile" elsewhere).
if (( WATCH_BOUNDARY_ONLY )); then
  required_tools="curl jq nc"
else
  required_tools="curl jq mpc nc"
fi
for tool in $required_tools; do
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
# Repeat guard: generic newline-separated "recently used" list, most recent
# entry last, capped at a caller-supplied size. Used for both the artist
# history (ARTIST_HISTORY_FILE/ARTIST_HISTORY_SIZE, entries are normalized
# artist names) and the track history (TRACK_HISTORY_FILE/
# TRACK_HISTORY_SIZE, entries are raw MPD file paths - NOT normalize()'d,
# since that would fold together distinct files that merely share
# whitespace/punctuation in their path).
# ---------------------------------------------------------------------------
history_contains() {
  local file="$1" entry="$2"
  [[ -f "$file" ]] || return 1
  grep -qxF "$entry" "$file"
}

history_add() {
  local file="$1" size="$2" entry="$3"
  touch "$file" 2>>"$DEBUG_LOG" || log "Warning: could not touch history file '$file'"
  # Written in ONE pass, in place (not via a temp file + "mv") - on some
  # devices (seen in practice: an overlay-root Volumio image where
  # /data/... files get individually tracked as their own overlay mount
  # once "copied up" into the writable layer), renaming OVER an existing
  # file fails with "Device or resource busy". That "mv" was an unguarded
  # command, so under "set -e" it silently killed the ENTIRE script right
  # here on every single run - invisible under cron, since cron's stderr
  # is normally redirected away, with nothing further ever getting
  # logged. Deduplicates (drop any existing occurrence of this entry so
  # it moves to the end instead of appearing twice), appends the new
  # entry, and trims to $size, all before ever touching the real file -
  # then writes the result with "cat > file" (truncate + write to the
  # existing inode, no rename() involved at all).
  { grep -vxF "$entry" "$file" 2>/dev/null || true; printf '%s\n' "$entry"; } \
    | tail -n "$size" > "${file}.tmp" 2>>"$DEBUG_LOG"
  cat "${file}.tmp" > "$file" 2>>"$DEBUG_LOG" || log "Warning: could not write history file '$file' - repeat guard may not persist this run"
  rm -f "${file}.tmp"
  return 0
}

mpd_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Sends one command over a fresh MPD connection and prints the raw
# response. "close" tells MPD to close the connection once it has sent
# the reply, so "nc" exits on its own instead of needing a fixed wait.
mpd_raw_query() {
  printf '%s\nclose\n' "$1" | nc -w 10 "$MPD_HOST" "$MPD_PORT" 2>>"$DEBUG_LOG"
}

# ---------------------------------------------------------------------------
# Volume normalization (replay gain) auto-management - optional
# (AUTO_REPLAYGAIN=on), off by default. Only touches MPD's global replay
# gain mode at two points: replaygain_sync() turns it on ("track" mode)
# once AutoDJ actually adds a track to the queue, and
# replaygain_reset_tracking() turns it back "off" at the next fresh-queue
# reset (step 1 below) - never on every single tick. Before acting,
# replaygain_sync() compares MPD's CURRENT mode against what this script
# itself last set (in REPLAYGAIN_STATE_FILE): if they differ, something
# else (almost certainly you, manually) changed it since - leave it alone
# rather than fight a deliberate choice, until the next fresh-queue reset
# resumes automatic management from a clean slate.
# ---------------------------------------------------------------------------
replaygain_query() {
  # MPD's native "replay_gain_status" reply looks like:
  #   replay_gain_mode: off
  #   OK
  mpd_raw_query "replay_gain_status" | sed -n 's/^replay_gain_mode: //p'
}

replaygain_set() {
  mpd_raw_query "replay_gain_mode $1" >/dev/null
}

replaygain_sync() {
  local desired="$1" last_set="" current

  [[ "$AUTO_REPLAYGAIN" == "on" ]] || return 0

  [[ -f "$REPLAYGAIN_STATE_FILE" ]] && last_set="$(cat "$REPLAYGAIN_STATE_FILE" 2>/dev/null)"

  current="$(replaygain_query)"
  if [[ -z "$current" ]]; then
    log "Volume normalization: could not read MPD's current replay gain mode - leaving it alone"
    return 0
  fi

  if [[ -n "$last_set" && "$current" != "$last_set" ]]; then
    log "Volume normalization: current mode '$current' differs from what this script last set ('$last_set') - looks like a manual change, leaving it alone until the next fresh queue"
    return 0
  fi

  if [[ "$current" != "$desired" ]]; then
    replaygain_set "$desired"
    log "Volume normalization: set replay gain mode to '$desired' (was '$current')"
  fi
  printf '%s' "$desired" > "$REPLAYGAIN_STATE_FILE" 2>>"$DEBUG_LOG"
}

# Called on a fresh-queue reset: this IS the designated point where
# automatic management resumes regardless of any manual change since -
# clears the tracking file first so replaygain_sync() above has nothing to
# compare against and just sets "off" outright.
replaygain_reset_tracking() {
  [[ "$AUTO_REPLAYGAIN" == "on" ]] || return 0
  rm -f "$REPLAYGAIN_STATE_FILE" 2>/dev/null || true
  replaygain_sync "off"
}

# ---------------------------------------------------------------------------
# Crossfade auto-management - optional (AUTO_CROSSFADE=<seconds>), off by
# default. Exactly the same on/off pattern as replaygain above, on the
# same two triggers, with the same manual-override detection - only the
# MPD command and query differ. Unlike replay_gain_status, MPD has no
# dedicated query command for crossfade; the current value is a field in
# the general "status" reply ("xfade: N"), which MPD only includes at all
# when crossfade is actually set to something nonzero - its absence is
# read as 0, not as a failed query.
# ---------------------------------------------------------------------------
crossfade_query() {
  local status_reply val
  status_reply="$(mpd_raw_query "status")" || return 1
  val="$(printf '%s' "$status_reply" | sed -n 's/^xfade: //p')"
  printf '%s' "${val:-0}"
}

crossfade_set() {
  mpd_raw_query "crossfade $1" >/dev/null
}

crossfade_sync() {
  local desired="$1" last_set="" current

  [[ "$AUTO_CROSSFADE" != "off" ]] || return 0

  [[ -f "$CROSSFADE_STATE_FILE" ]] && last_set="$(cat "$CROSSFADE_STATE_FILE" 2>/dev/null)"

  if ! current="$(crossfade_query)"; then
    log "Crossfade: could not read MPD's current crossfade setting - leaving it alone"
    return 0
  fi

  if [[ -n "$last_set" && "$current" != "$last_set" ]]; then
    log "Crossfade: current value '${current}s' differs from what this script last set ('${last_set}s') - looks like a manual change, leaving it alone until the next fresh queue"
    return 0
  fi

  if [[ "$current" != "$desired" ]]; then
    crossfade_set "$desired"
    log "Crossfade: set to ${desired}s (was ${current}s)"
  fi
  printf '%s' "$desired" > "$CROSSFADE_STATE_FILE" 2>>"$DEBUG_LOG"
}

# Same role as replaygain_reset_tracking() above - resumes automatic
# management from a clean slate at the next fresh-queue reset, regardless
# of any manual change since.
crossfade_reset_tracking() {
  [[ "$AUTO_CROSSFADE" != "off" ]] || return 0
  rm -f "$CROSSFADE_STATE_FILE" 2>/dev/null || true
  crossfade_sync 0
}

# ---------------------------------------------------------------------------
# "--watch-boundary" mode: see the header comment near WATCH_BOUNDARY_ONLY
# above. Polls Volumio's own REST getstate, exactly like the main queue
# check below, rather than MPD's raw "status" reply - confirmed on a real
# device that MPD's own "song:"/"playlistlength:" fields do NOT track
# Volumio's queue position at all when MPD is running in consume mode
# (playlistlength stayed "1" throughout, since Volumio feeds MPD one track
# at a time rather than loading the whole queue into MPD's own playlist);
# only Volumio's REST API actually reflects the queue position this
# script's boundary bookkeeping is based on. Costs one small curl+jq round
# trip per tick - more than a bare MPD query, but still far cheaper than
# the full queue-refill logic (no Last.fm calls, no mpc library scans).
# ---------------------------------------------------------------------------
WATCH_INTERVAL="${AUTODJ_WATCH_INTERVAL:-5}"

boundary_watch_tick() {
  [[ "$AUTO_REPLAYGAIN" == "on" || "$AUTO_CROSSFADE" != "off" ]] || return 0

  local watch_state_json current_position
  watch_state_json="$(curl -sf --max-time 5 "${api_base}/getstate")" || return 0

  # Same "Repeat All"/"Repeat Single" pause as the main tick (see the
  # comment there): with repeat on, position legitimately wraps back to 0
  # at the end of every lap, which would otherwise look exactly like a
  # fresh session to the edge-triggered detection just below and
  # incorrectly clear the boundary / reset replay gain+crossfade on every
  # single loop. Reuses the getstate response already fetched above - no
  # extra request.
  if [[ "$(jq_safe '.repeat // false' 'false' "$watch_state_json")" == "true" ]] ||
     [[ "$(jq_safe '.repeatSingle // false' 'false' "$watch_state_json")" == "true" ]]; then
    return 0
  fi

  current_position="$(jq_safe '.position // empty' '' "$watch_state_json")"
  [[ -n "$current_position" ]] || return 0

  # Own, faster-than-the-main-tick fresh-queue detection - same
  # edge-triggered "transition INTO position 0" pattern as the main tick's
  # (step 1 below), but tracked in its OWN file (WATCH_LAST_POSITION_FILE),
  # never LAST_POSITION_FILE - sharing that file would let whichever of the
  # two processes happens to observe the transition first "consume" it,
  # silently skipping the main tick's OWN reset of the repeat-guard
  # history. Needed because relying solely on the main tick to clear
  # MIXED_BOUNDARY_FILE leaves a window - up to a full main-tick interval -
  # where a STALE boundary left over from the previous mixed session could
  # incorrectly re-trigger replay gain/crossfade on fresh, deliberately
  # curated content, if the new queue's position happens to climb back up
  # past that old boundary value before the main tick gets a chance to run.
  local watch_last_position=""
  if [[ -f "$WATCH_LAST_POSITION_FILE" ]]; then
    watch_last_position="$(cat "$WATCH_LAST_POSITION_FILE" 2>/dev/null)" || true
  fi
  if (( current_position == 0 )) && [[ "$watch_last_position" != "0" ]] && [[ -f "$MIXED_BOUNDARY_FILE" ]]; then
    log "Boundary watcher: fresh queue detected (position=0) - clearing mixed-content boundary and resetting replay gain/crossfade"
    rm -f "$MIXED_BOUNDARY_FILE" 2>/dev/null || true
    replaygain_reset_tracking
    crossfade_reset_tracking
  fi
  printf '%s' "$current_position" > "$WATCH_LAST_POSITION_FILE" 2>>"$DEBUG_LOG" || true

  [[ -f "$MIXED_BOUNDARY_FILE" ]] || return 0
  local mixed_boundary
  mixed_boundary="$(cat "$MIXED_BOUNDARY_FILE" 2>/dev/null)" || true
  [[ -n "$mixed_boundary" ]] || return 0

  if (( current_position >= mixed_boundary )); then
    replaygain_sync "track"
    crossfade_sync "$AUTO_CROSSFADE"
  fi
}

run_boundary_watch_loop() {
  log "Boundary watcher started (polling every ${WATCH_INTERVAL}s)"
  while true; do
    boundary_watch_tick
    sleep "$WATCH_INTERVAL"
  done
}

if (( WATCH_BOUNDARY_ONLY )); then
  run_boundary_watch_loop
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Check Volumio's current playback state and queue.
# ---------------------------------------------------------------------------
state_json="$(curl -sf --max-time 10 "${api_base}/getstate")" || {
  log "Could not reach Volumio's REST API at $api_base (getstate) - is VOLUMIO_HOST/VOLUMIO_PORT correct?"
  exit 1
}
status="$(jq_safe '.status // empty' '' "$state_json")"

if [[ "$status" != "play" ]]; then
  log "Volumio status is '$status' (not 'play') - nothing to do"
  exit 0
fi

# Web radio streams have no track/artist to seed from and no meaningful
# "position in the queue" (they're not consumed like queued tracks) - stop
# here rather than let the queue-low check below fire on a stream that was
# never going to run out in the first place.
track_type="$(jq_safe '.trackType // empty' '' "$state_json")"
if [[ "$track_type" == "webradio" ]]; then
  log "Currently playing a web radio stream (trackType=webradio) - nothing to do"
  exit 0
fi

# "Repeat All" (or "Repeat Single") means the user wants THIS queue to loop
# unchanged, not grow - stop here, before ever touching the queue, the
# repeat-guard history, or replay gain/crossfade. Deliberately checked
# BEFORE the fresh-queue detection below: with repeat on, Volumio's own
# position legitimately wraps back to 0 at the end of every lap, which
# would otherwise look exactly like a brand new session starting and wipe
# out the repeat-guard history (and reset replay gain/crossfade) on every
# single loop - confirmed live (getstate) that Volumio exposes this as two
# separate booleans, "repeat" (all) and "repeatSingle".
repeat_all="$(jq_safe '.repeat // false' 'false' "$state_json")"
repeat_single="$(jq_safe '.repeatSingle // false' 'false' "$state_json")"
if [[ "$repeat_all" == "true" || "$repeat_single" == "true" ]]; then
  log "Repeat is enabled in Volumio (repeat=$repeat_all, repeatSingle=$repeat_single) - nothing to do"
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

# Position 0 is a strong signal the user just started something completely
# new (a single track, or a whole album/playlist queued from scratch) -
# reset the repeat-guard history in that case so leftover artists from an
# entirely different previous listening session don't block otherwise-fresh
# candidates for this new one. A queue_len or artist-overlap check was
# considered and dropped: both would miss valid resets whenever the new
# queue happens to share an artist with the old history, which costs more
# than the rare false positive here (manually rewinding to track 1 of the
# same still-running queue just resets the guard a little early).
#
# Edge-triggered, not level-triggered: only reset on the TRANSITION into
# position 0 (last-seen position, from LAST_POSITION_FILE, was something
# else), not on every run that merely finds position still at 0. The first
# track of a fresh session often takes longer to play than one check
# interval, so position can legitimately stay 0 across several runs in a
# row - reacting to the level rather than the edge would then wipe out the
# very history AutoDJ just built up during those same runs (confirmed in
# practice: a track added while position was still 0 got its history
# entry erased one tick later, making it eligible to repeat far sooner
# than TRACK_HISTORY_SIZE should have allowed).
last_position=""
[[ -f "$LAST_POSITION_FILE" ]] && last_position="$(cat "$LAST_POSITION_FILE" 2>/dev/null)"

if (( position == 0 )) && [[ "$last_position" != "0" ]] && { [[ -s "$ARTIST_HISTORY_FILE" ]] || [[ -s "$TRACK_HISTORY_FILE" ]]; }; then
  log "Fresh queue detected (position=0) - resetting repeat-guard history from the previous session"
  : > "$ARTIST_HISTORY_FILE"
  : > "$TRACK_HISTORY_FILE"
  replaygain_reset_tracking
  crossfade_reset_tracking
  rm -f "$MIXED_BOUNDARY_FILE" 2>/dev/null || true
fi

printf '%s' "$position" > "$LAST_POSITION_FILE" 2>>"$DEBUG_LOG" || log "Warning: could not persist last-seen queue position"

# AutoDJ appends to the END of the queue, but up to QUEUE_LOW_THRESHOLD
# tracks from the original, deliberately curated queue can still be ahead
# of the current position when it does - those should keep playing under
# your own normal settings, not the "mixed session" ones, even though
# AutoDJ has already added something after them. So replaygain/crossfade
# only turn on once playback actually REACHES the first AutoDJ-added
# track (MIXED_BOUNDARY_FILE, set below when that track is appended) -
# checked every tick, not just on the tick that adds it, since playback
# advances between runs regardless of whether anything new gets added.
if [[ -f "$MIXED_BOUNDARY_FILE" ]]; then
  mixed_boundary="$(cat "$MIXED_BOUNDARY_FILE" 2>/dev/null)" || true
  if [[ -n "$mixed_boundary" ]] && (( position >= mixed_boundary )); then
    replaygain_sync "track"
    crossfade_sync "$AUTO_CROSSFADE"
  fi
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
history_add "$ARTIST_HISTORY_FILE" "$ARTIST_HISTORY_SIZE" "$norm_seed"

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

# "mapfile"/"readarray" needs bash 4.0+, which isn't a given on every
# device this script might run on (e.g. macOS still ships bash 3.2 by
# default) - a plain "while read" loop works on any bash version instead.
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
  log "Could not read the local artist list from MPD ($MPD_HOST:$MPD_PORT) - is it reachable? (check bind_to_address in Volumio's mpd.conf)"
  exit 1
fi

# Parallel arrays instead of "declare -A" (associative arrays also need
# bash 4.0+, same as mapfile above) - normalized name in local_norm[i]
# maps to the real, as-tagged name in local_real[i] at the same index.
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

# ---------------------------------------------------------------------------
# Tidal fallback (automatic - no separate on/off switch): for a candidate
# NOT found in the local library, also search Tidal via Volumio's own
# /api/v1/search - confirmed on a real device to already return
# fully-formed track items (uri, title, artist, album, service, type) for
# anything Tidal has, so there's no need to hand-build a "tidal://..." uri
# the way the local lookup needs a URI_PREFIXES mapping. Naturally a no-op
# wherever Tidal isn't set up as a Volumio source: the search response then
# simply carries no "service": "tidal" items at all, so no separate "is
# Tidal available" check is needed either - it falls out of the same
# result set. Filters by the "service"/"type" fields rather than any
# list's title text (e.g. a German "TIDAL Titel") to stay independent of
# Volumio's own UI language setting.
#
# Only ever tried AFTER a local match already failed (see the candidate
# loops below) - never changes which candidate wins when both are
# available, only widens what counts as "found" for one that isn't local.
#
# Populates the SAME files/titles/albums arrays step 5 below already uses
# for local matches - the caller must reset them first (same convention as
# collect_files_by_artist()). Post-filters to an exact (normalized) artist
# match, same reasoning as the local "search" fallback needing one:
# Volumio's own search is fuzzy/substring, not exact. Also records the
# artist name exactly as Tidal has it tagged (tidal_matched_artist_name),
# mirroring find_local_artist() returning the locally-tagged canonical
# name rather than the raw Last.fm candidate string. Purely a curl+jq call
# against Volumio's REST API - no "mpc"/"nc" dependency, so it works
# identically here as in the local (SSH) variant of this script.
# ---------------------------------------------------------------------------
tidal_find_track() {
  local target_artist="$1" target_norm search_json uri title album artist_field

  target_norm="$(normalize "$target_artist")"
  tidal_matched_artist_name=""

  search_json="$(curl -sf --max-time 10 "${api_base}/search?query=$(urlencode "$target_artist")")" || return 1

  while IFS=$'\x1f' read -r uri title album artist_field; do
    [[ -z "$uri" ]] && continue
    [[ "$(normalize "$artist_field")" == "$target_norm" ]] || continue
    files+=("$uri")
    titles+=("$title")
    albums+=("$album")
    [[ -z "$tidal_matched_artist_name" ]] && tidal_matched_artist_name="$artist_field"
  done < <(printf '%s' "$search_json" | jq -r '
      .navigation.lists[]?.items[]? | select(.service == "tidal" and .type == "song") |
      [.uri, .title, (.album // ""), (.artist // "")] | join("\u001f")
    ' 2>>"$DEBUG_LOG")

  (( ${#files[@]} > 0 ))
}

chosen_artist=""
chosen_source="local"
for cand in "${candidates[@]}"; do
  [[ -z "$cand" ]] && continue
  norm_cand="$(normalize "$cand")"
  if history_contains "$ARTIST_HISTORY_FILE" "$norm_cand"; then
    log "Skipping '$cand' (recently used, repeat guard)"
    continue
  fi
  if real_match="$(find_local_artist "$norm_cand")"; then
    chosen_artist="$real_match"
    chosen_source="local"
    log "Match found in local library: '$cand' -> '$chosen_artist'"
    break
  fi
  files=(); titles=(); albums=()
  if tidal_find_track "$cand"; then
    chosen_artist="$tidal_matched_artist_name"
    chosen_source="tidal"
    log "Not in local library - match found on Tidal instead: '$cand' -> '$chosen_artist'"
    break
  fi
done

# ---------------------------------------------------------------------------
# 4b. Still nothing? Retry with up to MAX_SEED_RETRIES different seed
#     artists picked at random from the WHOLE queue (not just the weighted
#     last-SEED_WINDOW_SIZE window used in step 2) before falling back to
#     the least-recently-used candidate below. A retry seed drawn from that
#     same narrow window is often pointless: artists that rank as mutually
#     "similar" on Last.fm tend to cluster in the local library too, so a
#     different seed from the same handful of recent tracks usually points
#     right back at the same few names already blocked by the repeat guard
#     (e.g. a run of Italo-disco/synth-pop tracks whose Last.fm neighbors
#     are all each other). Pulling from the full queue gives a real chance
#     of escaping such a genre clique. Best-effort: a failed request here
#     just means one less retry, not an aborted run - the initial seed's
#     Last.fm call already succeeded, so this is strictly on top of that.
# ---------------------------------------------------------------------------
try_alternate_seed() {
  local seed="$1" url json err line cand norm_cand real_match

  url="http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar&artist=$(urlencode "$seed")&api_key=${LASTFM_API_KEY}&format=json&limit=${CANDIDATE_LIMIT}"
  json="$(curl -sf --max-time 10 "$url")" || {
    log "Retry: Last.fm request failed for alternate seed '$seed'"
    return 1
  }

  err="$(jq_safe '.message // empty' '' "$json")"
  if [[ -n "$err" ]]; then
    log "Retry: Last.fm returned an error for alternate seed '$seed': $err"
    return 1
  fi

  candidates=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    candidates+=("$line")
  done < <(printf '%s' "$json" | jq -r '.similarartists.artist[]?.name // empty')

  if (( ${#candidates[@]} == 0 )); then
    log "Retry: Last.fm returned no similar artists for alternate seed '$seed'"
    return 1
  fi

  for cand in "${candidates[@]}"; do
    [[ -z "$cand" ]] && continue
    norm_cand="$(normalize "$cand")"
    if history_contains "$ARTIST_HISTORY_FILE" "$norm_cand"; then
      log "Retry: skipping '$cand' (recently used, repeat guard)"
      continue
    fi
    if real_match="$(find_local_artist "$norm_cand")"; then
      chosen_artist="$real_match"
      chosen_source="local"
      log "Retry with alternate seed '$seed': match found in local library: '$cand' -> '$chosen_artist'"
      return 0
    fi
    files=(); titles=(); albums=()
    if tidal_find_track "$cand"; then
      chosen_artist="$tidal_matched_artist_name"
      chosen_source="tidal"
      log "Retry with alternate seed '$seed': not in local library - match found on Tidal instead: '$cand' -> '$chosen_artist'"
      return 0
    fi
  done

  return 1
}

if [[ -z "$chosen_artist" ]]; then
  tried_seeds=("$(normalize "$seed_artist")")
  retries=0
  while (( retries < MAX_SEED_RETRIES )) && [[ -z "$chosen_artist" ]]; do
    retry_pool=()
    for a in "${queue_artists[@]}"; do
      [[ -z "$a" ]] && continue
      norm_a="$(normalize "$a")"
      already_tried=0
      for t in "${tried_seeds[@]}"; do
        [[ "$norm_a" == "$t" ]] && { already_tried=1; break; }
      done
      (( already_tried )) && continue
      retry_pool+=("$a")
    done

    if (( ${#retry_pool[@]} == 0 )); then
      log "No more distinct queue artists left to retry with"
      break
    fi

    retry_seed="${retry_pool[$(( RANDOM % ${#retry_pool[@]} ))]}"
    tried_seeds+=("$(normalize "$retry_seed")")
    retries=$(( retries + 1 ))
    log "No fresh match for '$seed_artist' - retrying (${retries}/${MAX_SEED_RETRIES}) with a different seed from the queue: '$retry_seed'"
    # "|| true": a failed/unsuccessful retry (return 1) must NOT abort the
    # whole script under "set -e" here - it's a bare statement, not part of
    # an if/while/&&, so its own failure would otherwise be fatal even
    # though it just means "try the next retry, or fall through to the LRU
    # fallback below" (caught by the isolated logic test for this loop).
    try_alternate_seed "$retry_seed" || true
  done
fi

# Nothing survived the repeat guard (nor any retry) - rather than let the queue run dry,
# fall back to whichever eligible candidate was used LEAST RECENTLY
# (earliest line in the history file) instead of simply the most similar
# one. Falling back to "most similar" would otherwise let two artists
# that mutually rank as each other's closest Last.fm match ping-pong
# forever: each run's seed becomes whichever one was just added, and its
# own most-similar fallback is the other one - bouncing between just the
# two of them instead of ever moving on. A repeated artist (picked at
# random from among their local tracks each time, same as any other pick
# - see below) is still preferable to playback simply stopping.
#
# Deliberately LOCAL-only, unlike the two loops above - by this point every
# candidate has already had its chance at both a local AND a Tidal match
# (and lost to the repeat guard either way), so this is specifically about
# reusing a previously-successful LOCAL pick rather than widening the
# search further; keeps this already-dense fallback path from growing a
# second, Tidal-flavored copy of itself for comparatively little benefit.
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
      line_no="$(grep -nxF "$norm_cand" "$ARTIST_HISTORY_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)"
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
    chosen_source="local"
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
# NOTE: this deliberately does NOT use "mpc find"/"mpc search". Newer mpc/
# libmpdclient releases (e.g. Homebrew's on macOS) send a "tagtypes ..."
# protocol negotiation command before running find/search, which requires
# MPD protocol 0.21+ - Volumio's own (much older, heavily patched) bundled
# MPD rejects it outright ("MPD error: wrong number of arguments for
# 'tagtypes'"), so "mpc find"/"mpc search" fail completely against Volumio
# whenever this script runs on a machine with a newer mpc than Volumio's
# MPD supports, even for an artist that unmistakably IS in the library
# (confirmed via "mpc list artist" just above). Same class of bug reported
# here for another MPD-protocol server:
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1002544
#
# Talking to MPD's line protocol directly via "nc" sidesteps mpc/
# libmpdclient (and its negotiation) entirely, so it works regardless of
# how old Volumio's bundled MPD is.
if [[ "$chosen_source" == "local" ]]; then
  norm_chosen="$(normalize "$chosen_artist")"

  # Parses a find/search response (repeated "file: ..." blocks, each with
  # assorted "Tag: value" lines) and appends the path/title/album of every
  # block whose Artist line normalizes to exactly the target artist, in
  # lockstep (same index across files/titles/albums). The post-filter
  # matters for "search" (substring match) - without it, an unrelated
  # artist whose name merely contains this one as a substring would also
  # match; it's a harmless no-op for "find" (exact match). Title/album are
  # picked up here (instead of a second query later) so the eventual
  # addToQueue call can send real metadata instead of just a bare uri.
  collect_files_by_artist() {
    local verb="$1" cur_file="" cur_artist="" cur_title="" cur_album="" line

    flush_current() {
      if [[ -n "$cur_file" && "$(normalize "$cur_artist")" == "$norm_chosen" ]]; then
        files+=("$cur_file")
        titles+=("$cur_title")
        albums+=("$cur_album")
      fi
    }

    while IFS= read -r line; do
      case "$line" in
        "file: "*)
          flush_current
          cur_file="${line#file: }"
          cur_artist=""
          cur_title=""
          cur_album=""
          ;;
        "Artist: "*) cur_artist="${line#Artist: }" ;;
        "Title: "*)  cur_title="${line#Title: }" ;;
        "Album: "*)  cur_album="${line#Album: }" ;;
        "ACK "*)
          log "MPD returned an error for '$verb artist \"$chosen_artist\"': $line"
          ;;
      esac
    done < <(mpd_raw_query "$verb artist $(mpd_quote "$chosen_artist")")
    flush_current
  }

  files=()
  titles=()
  albums=()
  collect_files_by_artist find

  if (( ${#files[@]} == 0 )); then
    log "MPD 'find artist \"$chosen_artist\"' returned nothing despite appearing in 'mpc list artist' - retrying with 'search' instead"
    collect_files_by_artist search
  fi

  if (( ${#files[@]} == 0 )); then
    log "No files found for '$chosen_artist' via 'find' or 'search' - skipping (check $DEBUG_LOG for MPD errors, or try manually: printf 'find artist \"%s\"\\nclose\\n' | nc $MPD_HOST $MPD_PORT)"
    exit 0
  fi
fi
# else: chosen_source == "tidal" - files/titles/albums were already
# populated by tidal_find_track() back in step 4/4b, nothing to do here.

# Prefer a track that isn't in the recent track history, so the exact
# same song doesn't repeat within the last TRACK_HISTORY_SIZE additions -
# the artist itself repeating sooner than that is fine (that's what the
# separate, normally-shorter ARTIST_HISTORY_SIZE controls). Falls back to
# the full set if every local track by this artist was used recently
# (small local catalog for them) - a repeated track is still better than
# skipping this run entirely.
eligible_indices=()
for (( i = 0; i < ${#files[@]}; i++ )); do
  if ! history_contains "$TRACK_HISTORY_FILE" "${files[$i]}"; then
    eligible_indices+=("$i")
  fi
done

if (( ${#eligible_indices[@]} == 0 )); then
  log "All ${#files[@]} local track(s) by '$chosen_artist' are in the recent track history - repeating one anyway"
  picked_index=$(( RANDOM % ${#files[@]} ))
else
  picked_index="${eligible_indices[$(( RANDOM % ${#eligible_indices[@]} ))]}"
fi

picked_file="${files[$picked_index]}"
picked_title="${titles[$picked_index]}"
picked_album="${albums[$picked_index]}"

# Fall back to the bare filename if the file has no Title tag - same
# fallback the main volumio-smart-playlists.sh script uses.
if [[ -z "$picked_title" ]]; then
  picked_title="${picked_file##*/}"
fi

if [[ "$chosen_source" == "tidal" ]]; then
  # tidal_find_track() already stored the complete, ready-to-use
  # "tidal://..." uri as the "file" identity - no prefix mapping needed
  # (unlike the local library, Tidal's own uri scheme is self-contained).
  # Volumio's own Tidal search results all carry "trackType": "tidal" -
  # hardcoded here to match rather than derived from a file extension that
  # doesn't exist for a streamed track.
  uri="$picked_file"
  picked_track_type="tidal"
  add_service="tidal"
else
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
  add_service="mpd"
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
  --arg service "$add_service" \
  '{uri: $uri, service: $service, title: $title, artist: $artist, album: $album, type: "song", trackType: $trackType}')"

add_response="$(curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' -d "$add_payload" "${api_base}/addToQueue")" || {
  log "addToQueue POST request failed for uri '$uri'"
  exit 1
}

log "Added '$picked_file' (artist: $chosen_artist) to the queue - response: $add_response"
history_add "$ARTIST_HISTORY_FILE" "$ARTIST_HISTORY_SIZE" "$(normalize "$chosen_artist")"
history_add "$TRACK_HISTORY_FILE" "$TRACK_HISTORY_SIZE" "$picked_file"

# Marks where AutoDJ-mixed content starts (see the boundary check in step
# 1 above) - only on the FIRST addition since the last fresh-queue reset,
# so the boundary always points at the earliest mixed track rather than
# creeping forward with every subsequent addition. $queue_len is the
# queue's length BEFORE this addition, i.e. exactly the index this new
# track now occupies.
if [[ ! -f "$MIXED_BOUNDARY_FILE" ]]; then
  printf '%s' "$queue_len" > "$MIXED_BOUNDARY_FILE" 2>>"$DEBUG_LOG" || log "Warning: could not persist mixed-content boundary"
  log "Marking queue position $queue_len as the start of AutoDJ-mixed content"
fi
