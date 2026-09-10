# Volumio AutoDJ

Continuous play for [Volumio](https://volumio.org/): once the play queue is
about to run out, picks a track by an artist similar to what's currently
playing (via the [Last.fm](https://www.last.fm/api/account/create) API),
matched against your local library, and appends it - so playback never
just stops.

Two scripts, for different setups:

- **`volumio-autodj.sh`** - runs on a **different device** than Volumio (a
  NAS, a Raspberry Pi, a PC - anything on the same network), talking to
  Volumio only over its REST API and MPD's network port. **No SSH access
  to Volumio needed at all.**
- **`volumio-autodj-local.sh`** - a simpler variant for users who **do**
  have SSH access to Volumio, running directly on Volumio itself via cron
  or a systemd timer.

Prefer a settings page in the Volumio UI over managing cron/environment
variables by hand? See the companion
[autodj-plugin](https://github.com/Celindir69/autodj-plugin) - it wraps
`volumio-autodj-local.sh` in an actual Volumio plugin (On/Off, interval,
Last.fm API key, repeat-guard size, all from **Settings → Plugins**), with
its own internal scheduler so no cron/SSH is needed for day-to-day use
once it's installed.

Works with any local music library on Volumio - no dependency on any
particular playlist-building setup. If you're also looking for a way to
build static playlists from artist/filter rules, check out the companion
project [Volumio-Smart-Playlists](https://github.com/Celindir69/Volumio-Smart-Playlists)
(and its own [smart-playlist-plugin](https://github.com/Celindir69/smart-playlist-plugin)).

## `volumio-autodj.sh` (no SSH access needed)

Talks to Volumio over the network:
- Volumio's own REST API (`http://<volumio-ip>:3000/api/v1/...`) to read
  the current queue/playback state and to append tracks.
- Volumio's MPD instance (`<volumio-ip>:6600`) to check whether a
  candidate artist is present in your local library and to pick a track -
  this is normally already reachable over the LAN by default on Volumio
  (the same port third-party MPD clients like MPDroid use), no config
  change needed in the common case.
- The [Last.fm API](https://www.last.fm/api/account/create) (free API key)
  for "similar artist" suggestions.

### How it decides what to add

Each run does at most one check and, if needed, adds exactly one track:

1. Reads Volumio's current state and queue. Does nothing if playback isn't
   currently `play`, or if the number of tracks left after the current one
   is still at or above `QUEUE_LOW_THRESHOLD`.
2. Otherwise, picks a seed artist via a **weighted random pick among the
   last `SEED_WINDOW_SIZE` queue entries** (most recent weighted highest -
   e.g. with the default of 5, the newest contributes 5x as many "tickets"
   as the oldest of the five) and asks Last.fm for artists similar to it
   (most similar first). Weighting across a small window instead of always
   using only the very last track keeps the similarity chain from
   pivoting entirely on a single, possibly atypical pick - `SEED_WINDOW_SIZE=1`
   reproduces the old "always the last track" behavior exactly.
3. Tries each candidate in order until one is found in the local library
   (checked via `mpc list artist`) - and skips any candidate that was used
   too recently (**artist repeat guard**: a small history file of the last
   `ARTIST_HISTORY_SIZE` artists, so the same artist isn't picked again
   right away).
4. Picks one random track by the matched artist, preferring one that isn't
   in the **track repeat guard** (the last `TRACK_HISTORY_SIZE` tracks
   actually added - a separate, normally larger history than the artist
   one, since hearing the same artist again soon is fine but hearing the
   exact same song again isn't), and appends it to the end of the queue
   via Volumio's `addToQueue` command.

This is deliberately simple/reactive (one track at a time, re-evaluated on
every run) rather than planning several tracks ahead - it naturally
"drifts" the similarity chain over time and needs no extra state beyond
the small repeat-guard history.

### Setup

1. Copy `volumio-autodj.sh` to the other device (not Volumio) and make it
   executable: `chmod +x volumio-autodj.sh`.
2. Requires `curl`, `jq`, `mpc`, and `nc` (netcat) on **that** device (not
   on Volumio) - `mpc` is only used for the simple `list artist` lookup;
   `nc` is used to speak MPD's own line protocol directly for the
   find/search step (see "Notes / limitations" below for why). `nc` is
   preinstalled on macOS and most Linux distributions; if missing, install
   `netcat-openbsd` (or equivalent).
3. Get a free Last.fm API key: https://www.last.fm/api/account/create
4. Run it periodically, e.g. every 1-2 minutes, via whatever scheduler the
   device it runs on has. Manual test run:
   ```bash
   VOLUMIO_HOST=192.168.1.50 LASTFM_API_KEY=xxxxxxxx ./volumio-autodj.sh
   ```
   - **Linux**: cron or a systemd timer.
     Cron example:
     ```
     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
     VOLUMIO_HOST=192.168.1.50
     LASTFM_API_KEY=xxxxxxxx
     */2 * * * * /path/to/volumio-autodj.sh >/dev/null 2>&1
     ```
   - **macOS**: a `launchd` LaunchAgent. Save the following as
     `~/Library/LaunchAgents/com.volumio.autodj.plist` (adjust the paths,
     `VOLUMIO_HOST`, and `LASTFM_API_KEY` - `PATH` includes both
     Homebrew locations since launchd's own default `PATH` doesn't
     include Homebrew's `bin`, which is where `mpc`/`jq` normally live if
     installed via `brew install mpc jq`):
     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
     <plist version="1.0">
     <dict>
         <key>Label</key>
         <string>com.volumio.autodj</string>

         <key>ProgramArguments</key>
         <array>
             <string>/bin/bash</string>
             <string>/Users/YOURUSERNAME/bin/volumio-autodj.sh</string>
         </array>

         <key>EnvironmentVariables</key>
         <dict>
             <key>PATH</key>
             <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
             <key>VOLUMIO_HOST</key>
             <string>192.168.1.50</string>
             <key>LASTFM_API_KEY</key>
             <string>xxxxxxxx</string>
         </dict>

         <key>StartInterval</key>
         <integer>90</integer>

         <key>RunAtLoad</key>
         <true/>

         <key>StandardOutPath</key>
         <string>/Users/YOURUSERNAME/Library/Logs/volumio-autodj.out.log</string>

         <key>StandardErrorPath</key>
         <string>/Users/YOURUSERNAME/Library/Logs/volumio-autodj.err.log</string>
     </dict>
     </plist>
     ```
     Then load it:
     ```bash
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.volumio.autodj.plist
     ```
     (On very old macOS versions where `bootstrap` isn't available, use
     `launchctl load -w ~/Library/LaunchAgents/com.volumio.autodj.plist`
     instead.) Check it's registered with
     `launchctl list | grep com.volumio.autodj`, and after editing the
     plist, unload (`launchctl bootout gui/$(id -u) ...` or
     `launchctl unload ...`) and load it again to pick up the change.
     `StartInterval` (seconds) is independent of - and typically shorter
     than - `QUEUE_LOW_THRESHOLD`'s own timing logic further below; the
     script itself decides on every run whether there's actually anything
     to do.

### Configuration (environment variables)

- `VOLUMIO_HOST` (required) - Volumio's IP/hostname.
- `LASTFM_API_KEY` (required) - your free Last.fm API key.
- `VOLUMIO_PORT` (default `3000`)
- `MPD_HOST` (default: same as `VOLUMIO_HOST`), `MPD_PORT` (default `6600`)
- `QUEUE_LOW_THRESHOLD` (default `3`) - refill once this few (or fewer)
  tracks remain after the currently playing one.
- `CANDIDATE_LIMIT` (default `20`) - how many similar artists to request
  from Last.fm per run.
- `SEED_WINDOW_SIZE` (default `5`) - how many of the most recent queue
  entries to weight-pick the seed artist from; `1` = always the last
  track (the old behavior).
- `ARTIST_HISTORY_SIZE` (default `4`) - how many recently-used artists the
  artist repeat guard remembers. Repeating the same artist isn't a big
  deal, so this is deliberately short.
- `TRACK_HISTORY_SIZE` (default `15`) - how many recently-added tracks the
  separate track repeat guard remembers, so the exact same song doesn't
  come back too soon even if its artist is fine to reuse sooner. Falls
  back to repeating a track anyway if an artist's whole local catalog was
  used within this window (small library for them).
- `MAX_SEED_RETRIES` (default `2`) - if every similar artist for the
  initial seed is blocked by the repeat guard, how many additional random
  seed artists from the queue to retry with before falling back to the
  least-recently-used candidate - see "Notes / limitations" below.
- `AUTO_REPLAYGAIN` (default `off`) - if `on`, the script also manages
  MPD's volume normalization automatically - see "Volume normalization"
  below.
- `AUTODJ_URI_PREFIXES` - maps the first path segment MPD reports for a
  track (its source label, e.g. `INTERNAL`/`USB`/`NAS`) to the prefix
  needed to build a Volumio queue `uri`. Newline-separated
  `label|uri_prefix` entries. Default:
  ```
  INTERNAL|music-library/
  USB|music-library/
  NAS|mnt/
  ```
- `AUTODJ_STATE_DIR` (default `~/.volumio-autodj`) - where the repeat-guard
  histories and debug log are stored, on the device this script runs on.

### Volume normalization

A mixed AutoDJ queue jumps between recordings with very different mastering
loudness, unlike a deliberately curated album/playlist where the levels
were probably already consistent - so it can be worth turning Volumio's
volume normalization on for AutoDJ-extended listening even if you normally
leave it off. Set `AUTO_REPLAYGAIN=on` to have the script manage this for
you automatically:

- Switches MPD's replay gain mode to `track` the first time AutoDJ actually
  adds a track to the queue (i.e. once it's genuinely "mixed").
- Switches it back to `off` at the next freshly-started queue (the same
  `position == 0` signal that resets the repeat guard, see above) - back
  to your own normal setting for deliberately curated listening.
- Never touches it on every single tick, and never overrides a manual
  change: before acting, it compares MPD's current mode against what it
  itself last set. If they differ, you (or something else) changed it
  since - it backs off and leaves your change alone until the next fresh
  queue resets tracking and resumes automatic management.

Off by default - most users manage this setting themselves via Volumio's
own UI and won't want a background script touching a global playback
option.

**Not bit-perfect.** MPD applies ReplayGain by scaling the audio samples
in software (`replay_gain_handler "software"`, MPD's default) before they
reach the output - by definition no longer a bit-identical copy of the
source file, however small the correction. If bit-perfect/direct playback
matters to you, weigh that against the benefit of not having tracks jump
wildly in loudness during a mixed AutoDJ session, and leave
`AUTO_REPLAYGAIN` off if bit-perfect wins out for you.

**Not the same setting as Volumio's own "Volume Normalization" toggle**
in the UI - that one controls MPD's separate `volume_normalization`
option (an on-the-fly loudness filter, no tags needed, but no live
runtime command either - changing it means rewriting mpd.conf and
restarting MPD, too disruptive to automate on a running queue). What this
script controls is MPD's tag-based **ReplayGain** (`replay_gain_mode`)
instead - a fixed, precomputed per-track/album gain read from the file's
own tags, switchable live with no playback interruption, but only
effective on files that actually carry `REPLAYGAIN_TRACK_GAIN`/
`REPLAYGAIN_ALBUM_GAIN` tags. Run `check-replaygain-coverage.sh` (see
below) to see how much of your library actually has them.

### Checking ReplayGain tag coverage

`check-replaygain-coverage.sh` is a standalone, one-off diagnostic - not
run periodically like the AutoDJ scripts. It scans your whole library and
reports how many tracks (and which albums) actually carry ReplayGain
tags, since `AUTO_REPLAYGAIN` above has no effect on files that lack
them. Run it directly on Volumio via SSH:

```bash
chmod +x check-replaygain-coverage.sh
./check-replaygain-coverage.sh
```

Defaults to `MPD_HOST=localhost`; override `MPD_HOST`/`MPD_PORT` to point
it at a different device. For a large library this can take a while (MPD
has no bulk way to query ReplayGain tags - it's one `readcomments`
round-trip per file); progress is printed every 200 tracks. Writes a
per-file `replaygain_coverage.tsv` (path configurable via `OUTPUT_TSV`)
alongside the console summary.

### Notes / limitations

- Only handles **appending** to the queue - it never removes or reorders
  existing entries, so manual changes you make in the meantime are never
  overwritten.
- If you're currently listening to a web radio station (`trackType` =
  `webradio` in Volumio's state), the script does nothing that run - there's
  no track/artist to seed from, and a radio stream isn't "running low" on
  queue positions the way a normal queue is.
- If none of the `CANDIDATE_LIMIT` similar artists for the current seed are
  in your local library, the run simply does nothing that time - it tries
  again with a (likely different) seed on the next scheduled run once the
  queue moves on. If candidates ARE in your library but every one of them
  was filtered by the artist repeat guard, the script retries with up to
  `MAX_SEED_RETRIES` (default 2) different seed artists picked at random
  from the whole current queue, each with its own fresh Last.fm lookup,
  before giving up on finding something new. This matters because artists
  that rank as mutually "similar" on Last.fm tend to cluster in a local
  library too - a run of Italo-disco/synth-pop tracks, say, whose Last.fm
  neighbors are mostly each other - so simply trying a different *recent*
  seed often just leads back to the same handful of names already blocked
  by the artist repeat guard; a seed pulled from further back in the queue has a
  real chance of breaking out of that clique. Only if none of those
  retries turn up anything fresh either does the guard get overridden as a
  last-resort fallback, picking the **least-recently-used** of the
  eligible candidates anyway (still a freshly-randomized track of theirs)
  - letting playback stop entirely would be worse than an occasional early
  repeat. Deliberately not the *most similar* eligible candidate here: two
  artists that mutually rank as each other's closest Last.fm match would
  otherwise ping-pong forever once both are "recently used" - each run's
  seed becomes whichever one was just added, and its own top fallback is
  the other one. Picking the least-recently-used one instead rotates
  through more of a genre clique rather than bouncing between just two
  artists.
- Separately, whichever artist ends up chosen, the track actually picked
  for them prefers one outside the track repeat guard too. If an artist's
  entire local catalog was already used within the last
  `TRACK_HISTORY_SIZE` additions (a small library for them), a track gets
  repeated anyway rather than skipping the run.
- Both repeat-guard histories are reset automatically on the TRANSITION
  into queue position 0 - a freshly-started session, whether a single
  track or a whole album/playlist queued at once - since otherwise
  artists from a completely different previous listening session would
  block otherwise-fresh candidates for the new one, and/or feed straight
  into the ping-pong situation above. Edge-triggered on purpose: if the
  first track of a session runs longer than one check interval, position
  legitimately stays 0 across several runs in a row, and resetting on
  every one of those (instead of just the first) would wipe out the
  history AutoDJ itself just built up in the meantime - letting a track
  added seconds earlier repeat far sooner than `TRACK_HISTORY_SIZE` should
  allow. The one downside is a rare false positive: manually rewinding to
  track 1 of the same still-running queue also resets the guard a little
  early, which is harmless.
- The Last.fm similarity graph can still drift fairly far from where you
  started over a long listening session, since `SEED_WINDOW_SIZE` only
  weights toward the last few queued artists, with no anchoring back to
  the artist you actually started with. Nothing in this script currently
  corrects for that.
- Debug log at `$AUTODJ_STATE_DIR/autodj.debug.log` on the device this
  script runs on.
- **Why `nc` instead of just `mpc find`/`mpc search`**: newer mpc/
  libmpdclient releases (e.g. the one Homebrew installs on macOS) send a
  `tagtypes ...` protocol negotiation command before running `find`/
  `search`, which requires MPD protocol 0.21+. Volumio's own bundled MPD
  is often older than that and rejects it outright (`MPD error: wrong
  number of arguments for "tagtypes"`), which makes `mpc find`/`mpc
  search` fail completely against Volumio - even for an artist that
  genuinely is in the library - whenever this script runs on a machine
  with a newer `mpc` than Volumio's MPD supports. (Same class of bug
  reported here for another MPD-protocol server:
  https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1002544.) The
  find/search step therefore talks to MPD's line protocol directly over a
  raw TCP connection (via `nc`), bypassing mpc/libmpdclient - and with it,
  that whole class of version-negotiation incompatibility - entirely. The
  simpler `mpc list artist` lookup elsewhere in the script is unaffected
  and still uses `mpc` normally.

## `volumio-autodj-local.sh` (SSH access to Volumio)

Same behavior and configuration variables as `volumio-autodj.sh`
(`LASTFM_API_KEY`, `QUEUE_LOW_THRESHOLD`, `CANDIDATE_LIMIT`,
`SEED_WINDOW_SIZE`, `ARTIST_HISTORY_SIZE`, `TRACK_HISTORY_SIZE`, `MAX_SEED_RETRIES`, `AUTO_REPLAYGAIN`,
`AUTODJ_URI_PREFIXES`), but runs
directly **on** Volumio itself via cron or a systemd timer, with these
differences:

- `VOLUMIO_HOST`/`MPD_HOST` default to `localhost` instead of being
  required - no IP/hostname to configure in the common case.
- No `nc` dependency and no raw-protocol workaround: it uses plain `mpc
  find`/`mpc search` directly. The version-mismatch problem described
  above only happens when an *independently installed* mpc talks to
  Volumio's MPD over the network - Volumio's own bundled `mpc` always
  matches its own bundled MPD, so that failure mode can't occur here.
- `AUTODJ_STATE_DIR` defaults to `/data/volumio_autodj_data` instead of
  `~/.volumio-autodj` (deliberately under `/data/`, not tied to a
  particular user's home directory).

### Setup

1. Copy `volumio-autodj-local.sh` to Volumio (e.g.
   `/usr/local/bin/volumio-autodj-local.sh`) and make it executable:
   `sudo chmod +x /usr/local/bin/volumio-autodj-local.sh`.
2. Requires `curl`, `jq`, and `mpc` - `mpc` is part of Volumio's base
   image already; install `jq` if needed:
   ```bash
   sudo apt-get update
   sudo apt-get install -y jq
   ```
3. Get a free Last.fm API key: https://www.last.fm/api/account/create
4. Schedule it every 1-2 minutes via cron or a systemd timer, e.g.:
   ```
   PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   LASTFM_API_KEY=xxxxxxxx
   */2 * * * * /usr/local/bin/volumio-autodj-local.sh >/dev/null 2>&1
   ```

### Known device quirk: overlay-root filesystems

On some Volumio images with an overlay-root filesystem (files under
`/data/...` get individually tracked as their own overlay mount once
"copied up" into the writable layer - visible via
`mount | grep <filename>` showing `type overlay` for that one file),
renaming a file over an existing one at the same path fails with
"Device or resource busy". This script writes its state files (repeat-
guard history, debug log rotation) in place rather than via a
temp-file-then-rename pattern specifically to avoid that failure mode
regardless of the underlying filesystem.

## License

Do whatever you want with it.
