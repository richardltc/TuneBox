# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies and set up assets
mix setup

# Start the dev server
mix phx.server
# or with IEx
iex -S mix phx.server

# Run all tests
mix test

# Run a specific test file
mix test test/path/to/test.exs

# Run previously failed tests
mix test --failed

# Pre-commit check (compile with warnings-as-errors, remove unused deps, format, test)
mix precommit

# Database
mix ecto.create
mix ecto.migrate
mix ecto.reset          # drop + create + migrate
mix ecto.rollback
```

The app runs at http://localhost:4000. Dev dashboard at http://localhost:4000/dev/dashboard.

## Architecture

TuneBox is a Phoenix 1.8 / LiveView 1.1 music player web app backed by SQLite (`ecto_sqlite3`). The web server is Bandit.

**Module namespacing:** The OTP app is `:tunebox`, the top-level module for business logic is `TuneBox.*`, and the web layer is `TuneboxWeb.*` (note the inconsistent casing — `TuneBox` vs `Tunebox`).

**External dependencies:** Requires `ffprobe` (ffmpeg) on `$PATH` to start. Requires `mpv` on `$PATH` for playback (conditionally added to supervision tree — app starts without it but playback is disabled).

### Core domains

- **`TuneBox.Music`** — Context module for the music library. Key functions: `list_live_tracks/0`, `refresh_live_tracks/1`, `delete_live_track/1`, `move_live_track/2`. Schemas:
  - `Artist` → has many `Album`s and `Track`s; stores `picture_big` binary (artwork)
  - `Album` → belongs to `Artist`, has many `Track`s; stores `cover_big` binary (artwork)
  - `Track` → belongs to `Artist` and optionally `Album`; `file_path` is the unique key
  - `LiveTrack` — join table for the player's ordered track queue (position + track_id)
  - `Importer` — walks a directory recursively, calls `ffprobe` to extract metadata, upserts into DB
  - `ArtworkFetcher` — fetches artist/album images from Deezer API, stores as binary in DB. Idempotent (only fetches when image column is nil)

- **`TuneBox.Player`** — GenServer that controls playback via `mpv`. Spawns an `mpv` subprocess in `--idle` mode and communicates via Unix domain socket using MPV IPC JSON protocol. Broadcasts playback events (`:time_pos`, `:duration`, `:track_ended`) via `Phoenix.PubSub` on topic `"player:status"`.

- **`TuneBox.Config`** — Single-row schema for persisting app settings (music folder path, paused playback state, remove_completed_tracks preference).

- **`TuneBox.App`** — App metadata (name, version) and OS-aware home folder path resolution (`~/.tunebox` on Linux, `~/Library/Application Support/TuneBox` on macOS, `AppData\Roaming\TuneBox` on Windows).

### Web layer

The root route (`/`) serves `TuneboxWeb.PlayerLive` — the main LiveView containing the track list, playback controls, search, import, and settings UI. This is currently the only route.

### Supervision tree

`Tunebox.Application` starts: Telemetry, DNSCluster, PubSub, Repo, Endpoint, and conditionally `TuneBox.Player` (only if `mpv` is on PATH). The `player_available` assign in the LiveView tracks whether Player is running.

### Key patterns

**LiveView streams with selection highlighting:** Stream items don't re-render when other assigns change. To update selection state visually, call `stream(:tracks, socket.assigns.track_list, reset: true)` to force all items to re-render. The LiveView maintains both `track_list` (ordered list) and `track_map` (id → track map) alongside the stream.

**Artwork fetching:** Triggered asynchronously via `Task.start/1` when a track is selected or auto-advanced. The task calls `ArtworkFetcher.fetch_for_track/1` then sends `:reload_tracks` back to the LiveView to refresh the UI with newly stored images.

**Playback state persistence:** When paused, the current track and position are saved to `TuneBox.Config`. On mount, the LiveView restores this state so playback can resume across page reloads.

### Key Phoenix 1.8 conventions (from AGENTS.md)

- LiveView templates must start with `<Layouts.app flash={@flash} ...>` — `TuneboxWeb.Layouts` is aliased in `tunebox_web.ex`
- Use `<.icon name="hero-*">` for Heroicons, never `Heroicons` modules
- Use `<.input>` component for form inputs from `core_components.ex`
- Use `<.link navigate={...}>` / `push_navigate` instead of deprecated `live_redirect`
- Use LiveView streams for collections (never assign raw lists for display)
- No embedded `<script>` tags in HEEx; JS goes in `assets/js/`
- HTTP requests: use `Req` (already a dep); avoid `:httpoison`, `:tesla`, `:httpc`
