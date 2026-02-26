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

### Core domains

- **`TuneBox.Music`** — Ecto schemas for the music library:
  - `Artist` → has many `Album`s and `Track`s
  - `Album` → belongs to `Artist`, has many `Track`s
  - `Track` → belongs to `Artist` and optionally `Album`; `file_path` is the unique key
  - `Importer` — walks a directory recursively, calls `ffprobe` to extract metadata, and upserts Artists/Albums/Tracks into the database. Requires `ffprobe` (ffmpeg) on `$PATH`.

- **`TuneBox.Player`** — GenServer that controls playback via `mpv`. Spawns an `mpv` subprocess in `--idle` mode and communicates via a Unix domain socket (or Windows named pipe) using the MPV IPC JSON protocol. Requires `mpv` on `$PATH`. Currently **not** started in `Application.start/2` (must be added to the supervision tree to use).

- **`TuneBox.App`** — App metadata (name, version) and OS-aware home folder path resolution (`~/.tunebox` on Linux, `~/Library/Application Support/TuneBox` on macOS, `AppData\Roaming\TuneBox` on Windows).

- **`TuneBox.Repo`** — Ecto repo using SQLite.

### Web layer

Standard Phoenix 1.8 structure with no LiveViews yet (only a `PageController` placeholder). The router has a single `GET /` route. LiveViews should go in the default `:browser` scope (already aliased to `TuneboxWeb`).

### Key Phoenix 1.8 conventions (from AGENTS.md)

- LiveView templates must start with `<Layouts.app flash={@flash} ...>` — `MyAppWeb.Layouts` is aliased in `tunebox_web.ex`
- Use `<.icon name="hero-*">` for Heroicons, never `Heroicons` modules
- Use `<.input>` component for form inputs from `core_components.ex`
- Use `<.link navigate={...}>` / `push_navigate` instead of deprecated `live_redirect`
- Use LiveView streams for collections (never assign raw lists for display)
- No embedded `<script>` tags in HEEx; JS goes in `assets/js/`
- HTTP requests: use `Req` (already a dep); avoid `:httpoison`, `:tesla`, `:httpc`
