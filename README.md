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

- <img width="1003" height="604" alt="Screenshot 2026-03-25 at 6 10 47 PM" src="https://github.com/user-attachments/assets/4885416f-5687-4778-a482-15158fcecce5" />
This is the home screen.
- <img width="1920" height="1080" alt="Screenshot 2026-03-25 at 6 13 10 PM (2)" src="https://github.com/user-attachments/assets/15da980b-8cbe-41be-8c80-59dde7aa7b23" />
This is what it looks like when you are dragging and dropping files.
- <img width="980" height="717" alt="Screenshot 2026-03-25 at 6 15 34 PM" src="https://github.com/user-attachments/assets/2ff16cde-a025-4956-a6f7-541bbfac52aa" />
Example from what my corpus looks like. 
- <img width="1681" height="652" alt="Screenshot 2026-03-25 at 6 23 09 PM" src="https://github.com/user-attachments/assets/6cf3a49d-45c0-4a30-a384-8fe1095a9e9d" />
Example from my Librarian of an answer.

## Roadmap

- Rename remaining legacy internal symbols where safe without schema breakage.
- Improve indexing controls (cancel/retry per import batch).
- Add richer source preview in citations panel.
- Add packaged sample screenshot assets and short demo GIF.
