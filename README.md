# Zed Thread Viewer

A unified browser for Zed conversations and threads with SQLite-based search.

Mostly vibe-coded, so kinda gnarly. But it's useful.

Slow in Safari when quickly switching selection becuase it locks up to load iframes. :/


## Features

- **Unified view** - Browse both conversations (*.zed.json) and threads (from threads.db)
- **Full-text search** - SQLite FTS5 search across titles and content
- **Star system** - Mark favorite items with ☆/★ toggle, filter starred-only
- **Dual view modes** - Switch between formatted markdown and raw JSON
- **Import system** - Processes and indexes both data sources
- **Split interface** - List on left, content on right
- **Type indicators** - Visual distinction between agent threads (𝐀) and text conversations (𝐓)
- **Keyboard shortcuts** - Full TUI-style keyboard navigation

## Setup

```bash
bundle install
ruby import.rb [datasources_path] [output_db]
```

Default paths:
- `datasources/conversations/` - Zed conversation files (*.zed.json)
- `datasources/threads/threads.db` - Zed threads database
- `datasources/unified.db` - Generated unified database
- `datasources/stars.db` - Star/favorite status database

## Usage

```bash
bundle exec rackup
# Development with auto-reload:
bundle exec rerun rackup
```

Open http://localhost:9292

## Data Sources

**Conversations**: JSON files containing chat sessions with metadata like slash command outputs and message roles.

**Threads**: Compressed thread data from Zed's SQLite database, supporting both v0.2.0 (role/segments) and v0.3.0 (User/Agent) formats.

## Interface

The app displays entries with format: `[star] [date] symbol [workspace] title`
- `☆/★` = unstarred/starred toggle
- `𝐀` = thread
- `𝐓` = conversation
- Date from file modification or thread update
- Workspace path when available

Content view toggles between markdown (with role labels and slash command highlighting) and formatted JSON with expandable blocks for long content.

Search works across all content using SQLite's FTS5 full-text search.

## Keyboard Shortcuts

- `/` - Focus search input
- `↑↓` - Navigate entries
- `c` - Copy selected title
- `f` - Toggle star on selected entry
- `j` - Toggle JSON/text view for content
- `v` - Toggle horizontal/vertical layout
- `r` - Rebuild database (re-import all data)

Status bar at bottom shows all available shortcuts.
