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
   too recently (**repeat guard**: a small history file of the last
   `HISTORY_SIZE` artists, so the same artist isn't picked again right
   away).
4. Picks one random track by the matched artist and appends it to the end
   of the queue via Volumio's `addToQueue` command.

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
- `HISTORY_SIZE` (default `15`) - how many recently-used artists the
  repeat guard remembers.
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
  history and debug log are stored, on the device this script runs on.

### Notes / limitations

- Only handles **appending** to the queue - it never removes or reorders
  existing entries, so manual changes you make in the meantime are never
  overwritten.
- If none of the `CANDIDATE_LIMIT` similar artists for the current seed are
  in your local library, the run simply does nothing that time - it tries
  again with a (likely different) seed on the next scheduled run once the
  queue moves on. If candidates ARE in your library but every one of them
  was filtered by the repeat guard, the guard is overridden as a fallback
  and the **least-recently-used** of the eligible candidates is picked
  anyway (still a freshly-randomized track of theirs) - letting playback
  stop entirely would be worse than an occasional early repeat.
  Deliberately not the *most similar* eligible candidate here: two
  artists that mutually rank as each other's closest Last.fm match would
  otherwise ping-pong forever once both are "recently used" - each run's
  seed becomes whichever one was just added, and its own top fallback is
  the other one. Picking the least-recently-used one instead rotates
  through more of a genre clique rather than bouncing between just two
  artists.
- The repeat-guard history is reset automatically whenever the queue
  position is 0 - a freshly-started session, whether a single track or a
  whole album/playlist queued at once - since otherwise artists from a
  completely different previous listening session would block
  otherwise-fresh candidates for the new one, and/or feed straight into
  the ping-pong situation above. The one downside is a rare false
  positive: manually rewinding to track 1 of the same still-running queue
  also resets the guard a little early, which is harmless.
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
`SEED_WINDOW_SIZE`, `HISTORY_SIZE`, `AUTODJ_URI_PREFIXES`), but runs
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
