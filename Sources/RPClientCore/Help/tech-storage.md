# Storage layer

[Storage.swift](Sources/RPClientCore/Storage.swift) is the thin file-system layer between the model objects and disk. It is deliberately small — there is no database, no migration framework, no caching. Every entity is a JSON file; every write is atomic.

## Layout

Everything persisted lives under `~/Library/Application Support/RPClient/`:

```
RPClient/
├── settings.json
├── chats/<uuid>.json
├── vectors/<uuid>.vec.json
├── characters/
│   ├── <uuid>.json
│   └── avatars/<uuid>.png
└── personas/
    ├── <uuid>.json
    └── avatars/<uuid>.png
```

`Storage.shared` is a singleton; the directory is created on first access. There's no migration step at boot — directories are made lazily.

## Atomic writes

Every persistent write goes through `atomicWrite(_:to:)` ([Storage.swift:249](Sources/RPClientCore/Storage.swift)):

```swift
private func atomicWrite(_ data: Data, to url: URL) {
    let tmp = url.appendingPathExtension("tmp")
    do {
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    } catch {
        try? data.write(to: url)
    }
}
```

The contract: a process kill anywhere in the middle of a save can never leave a half-written file. The temp file is itself written atomically (`.atomic`), and the swap to the real path is filesystem-atomic via `replaceItemAt`. The fallback `data.write(to: url)` at the end is a "better than nothing" path for unusual filesystems where the rename fails.

## Encoder / decoder

One pair of `JSONEncoder` / `JSONDecoder` per `Storage` instance, configured at init:

- `outputFormatting = [.prettyPrinted, .sortedKeys]` — diff-friendly on disk; you can `git diff` two snapshots and the changes will be readable.
- `dateEncodingStrategy = .iso8601` — same on both sides.

`sortedKeys` is what makes the on-disk format inspectable with `jq` and stable across saves; `.prettyPrinted` is what makes it human-readable.

## Schema versioning

There's no formal migration framework. Models that have evolved (notably [Chat](Sources/RPClientCore/Models/Chat.swift) and [WorldInfoEntry](Sources/RPClientCore/Models/WorldInfoEntry.swift)) handle migrations in their custom `init(from decoder:)`:

```swift
serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? d.serverURL
```

Pattern: every field is decoded with `decodeIfPresent` and falls back to a default. This makes the format **forward-compatible** (newer code reads older files cleanly) and **backward-compatible** (older code reads newer files, ignoring unknown keys).

The current schema is **Chat v3** (post-2026-05-03 entity-store dedup migration). When a `Chat` decodes with `schemaVersion < 3`, `Chat.dedupeMigratedEntities` runs to collapse legacy `name="[type] X" / type=event` rows into typed twins, then bumps the schema. This is the one place the storage layer carries a one-shot transformation.

## Listing

`listChats() / listCharacters() / listPersonas()` walk the directory, decode every `.json`, and return them sorted (chats by `modified` desc, others by `created` desc). There's no index file — directory listing is the index.

This is fine at the scale the app is used at. If chat counts ever go past a few thousand and listing becomes noticeable on launch, an index-on-write pattern would close that, but it's not warranted today.

## Vector store persistence

`VectorStore.save() / load()` ([Memory/VectorStore.swift](Sources/RPClientCore/Memory/VectorStore.swift)) write the per-chat vector index to `vectors/<uuid>.vec.json` directly, bypassing `Storage.atomicWrite`. They use `Data.write(to:options: .atomic)` themselves. The path is owned by `Storage.vectorsDir` so cleanup on chat delete still goes through `Storage.deleteChat`.

Safe to delete a `vectors/<uuid>.vec.json` by hand — RPClient will re-index from the chat on the next save.

## Avatars

PNG files written via `atomicWrite(pngData, to: ...)`. Avatar paths are derived from the entity's id, so a card/persona JSON without an accompanying avatar still loads cleanly — the missing avatar is just the absent file.

The `chara` PNG text-chunk extraction lives in [PNGTextChunks.swift](Sources/RPClientCore/Importers/PNGTextChunks.swift), called from [CharacterCardImporter.swift](Sources/RPClientCore/Importers/CharacterCardImporter.swift) when importing a `.png` card.

## What lives elsewhere

- **Settings hand-edits** are safe while RPClient is closed; on next launch Settings reloads via `Storage.loadSettings()`.
- **The debug log** is at `$TMPDIR/rpclient-debug.log`, not under Application Support — it's transient by design.
