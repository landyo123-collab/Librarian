# Librarian

Librarian is a local-first macOS research app that turns your folders into a grounded assistant: it indexes documents and source code, runs hybrid lexical + semantic retrieval, and answers with evidence-backed responses plus reusable distilled notes.

## Features

- Local corpus management with a fixed canonical library path.
- Source-aware parsing for Markdown/text plus Swift and Python code.
- SQLite + FTS5 indexing with hybrid retrieval.
- Citation-aware answer flow and reusable distilled notes.
- Generic trigger pipeline (`CSV -> JSON`) with safe runtime fallback.
- Drag-and-drop folder import with collision-safe naming and auto-indexing.

## How It Works

1. **Corpus location**  
   Librarian always uses `~/Documents/Librarian/UserLibrary/` as the corpus folder and creates it on startup if missing.
2. **Import and indexing**  
   You drag folders into the app; Librarian copies them into `UserLibrary`, then runs indexing (or queues a follow-up pass if one is already running).
3. **Embeddings**  
   Run embeddings after indexing to refresh semantic retrieval.
4. **Answering**  
   Queries use hybrid retrieval and return grounded responses with source-aware context.
5. **Memory**  
   Distilled notes are saved locally and reused to improve follow-up answers.

## Drag-and-Drop + UserLibrary Flow

- Drop folders directly onto the main window.
- Only directories are imported.
- Import destination is always `~/Documents/Librarian/UserLibrary/`.
- Name collisions are resolved as `Folder`, `Folder-2`, `Folder-3`, etc.
- UI shows drag-target state, import success/failure status, and queued indexing status.
- Use **Index Documents** and **Generate Embeddings** to refresh corpus context at any time.

## Privacy and Local-First

- Corpus files stay on your machine in `~/Documents/Librarian/UserLibrary/`.
- SQLite database stays local in `~/Library/Application Support/Librarian/librarian.db`.
- No private corpus assumptions or private framework registries are required.
- API calls for reasoning/embeddings use your configured keys (`DEEPSEEK_API_KEY`, `OPENAI_API_KEY`).

## Trigger Pipeline

Trigger resources:

- `Resources/triggers/triggers-base.csv`
- `Resources/triggers/triggers-generated.json`
- `Scripts/build_triggers.py`

Build/update triggers:

```bash
python3 Scripts/build_triggers.py
```

Runtime load order:

1. `LIBRARIAN_TRIGGER_PATH` (if set)
2. Auto-detected `Resources/triggers/triggers-generated.json`
3. Built-in default trigger set

## Repo Structure

- `IdeaLibrarian/` — app + core implementation
- `SampleLibrary/` — tracked demo corpus
- `UserLibrary/` — repo placeholder only (`.gitkeep`); runtime corpus path is in `~/Documents/...`
- `Resources/triggers/` — trigger data assets
- `Scripts/` — utility scripts
- `screenshots/` — screenshot placeholders for GitHub docs

## Build and Run

### Requirements

- macOS 13+
- Xcode 15+ (or Swift 5.9+)
- `DEEPSEEK_API_KEY`
- `OPENAI_API_KEY`

### Setup

```bash
cp .env.example .env
```

Add keys to `.env` (or export as environment variables).

### Xcode

1. Open `IdeaLibrarian.xcodeproj`
2. Run `IdeaLibrarian`

### SwiftPM

```bash
swift build
swift run Librarian
```

## Screenshots

Add/replace these files when preparing the repo page:

- `screenshots/01-main-window.png`
- `screenshots/02-drag-import.png`
- `screenshots/03-index-and-embeddings.png`
- `screenshots/04-grounded-response.png`

## Roadmap

- Rename remaining legacy internal symbols where safe without schema breakage.
- Improve indexing controls (cancel/retry per import batch).
- Add richer source preview in citations panel.
- Add packaged sample screenshot assets and short demo GIF.
