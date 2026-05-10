# Multi-server

RPClient can talk to more than one KoboldCpp instance at the same time. Each chat picks one server (or falls back to the global default), and the side-calls — summarizer, fact extractor, embeddings — can each be routed to a different server too.

The common shape: one big model on a workstation handles chat replies, while a small fast model on the same or another machine handles summarization and fact extraction. There's no requirement to use multiple servers — the default config is one entry called "Default" pointing at `http://localhost:5001`, which behaves exactly like the pre-V8 single-server world.

## Servers section in Settings

`Settings… → Servers` is the editor. Each row is a profile with:

- **Name** — display label. Free-form ("Workstation", "Tiny model", "Cloud").
- **URL** — `http://host:port` of a running KoboldCpp instance.
- **Status dot** — `●` after a successful probe, dim when not yet probed, red on failure. Hover for the detected model name.
- **Test** — fires a short probe (`/api/v1/model`, `/api/extra/version`, `/api/extra/true_max_context_length`) so you can verify the server before relying on it.
- **×** — delete. The default server is non-deletable; re-point Default to another profile first.

Below the list: **+ Add server**.

Below that: four role-assignment popups.

## Role assignment

Four roles, each independent:

| Role | Used for |
|---|---|
| **Default (chat)** | The main reply generation. Required — must point to a real profile. |
| **Summarizer** | The rolling-summary side-call. Optional — `(use default)` falls back to the chat server. |
| **Extractor** | The fact-extractor side-call. Optional. |
| **Embeddings** | Vector retrieval. Optional. |

The optional roles are a fallback chain: if the assigned profile is missing, RPClient falls back to the chat default. This makes it safe to delete a profile that a side-call was pointing at — the side-call resumes against the default rather than failing.

## Per-chat server pin

The chat header has a server picker just to the left of the template / preset pickers. Two states:

- **(use default)** — the chat reads `Settings → Servers → Default (chat)` at send time. Recommended unless you have a specific reason to pin.
- **A specific profile** — the chat always uses that server, regardless of what the global default is.

Per-chat pinning is what you want when you have a long chat tied to a particular model and you don't want a Settings change to affect that one chat. It is also what you want when running multiple chats in parallel against different models.

## Probes

When you click **Test** (or open the Settings sheet), RPClient runs a short probe against the URL: `/api/v1/model`, `/api/extra/version`, `/api/extra/true_max_context_length`. Results are stored as `ServerCapabilities` on the profile and surface as the status-dot tooltip plus a small last-probed timestamp. Probes are short-timeout — they fail fast on a wrong URL rather than blocking the UI.

The status dot is informational. A red dot doesn't stop you from saving the profile; it just tells you the URL didn't respond. This matters when you're configuring a server that isn't running yet — you can save the profile and probe later.

## Worked examples

### One workstation, one cloud fallback

You have a beefy local KoboldCpp for the main reply and a smaller cloud instance for cheap side-calls.

1. **Settings → Servers → + Add server.** Name `Workstation`, URL `http://192.168.1.50:5001`. Test, expect green dot.
2. **+ Add server** again. Name `Cloud-7B`, URL `https://my-cloud.example.com:5001`. Test.
3. Role popups: Default = `Workstation`. Summarizer = `Cloud-7B`. Extractor = `Cloud-7B`. Embeddings = `(use default)`.
4. Save. Existing chats will continue using the Default; new chats inherit it too.

The chat reply runs on the workstation; summary and fact-extraction side-calls land on the cloud instance.

### One chat pinned to a specific model

You're 200 turns into a chat against a Qwen3-32B model and someone else needs to use that workstation. You want to switch the global default to a smaller server *without* breaking that one chat.

1. Chat header → server picker → pick the workstation profile (so the chat is now pinned).
2. **Settings → Servers** → set Default (chat) to a different profile.
3. Save.

Other chats now use the new default; the pinned chat keeps using the workstation.

### Recovering from a deleted profile

You deleted a profile that summarizer was pointing at.

The role assignment doesn't *break* — the registry's resolver detects the dangling reference, treats it as `nil`, and falls back to the default. The Settings UI repaints the role popup as `(use default)` next time it's opened. Nothing to fix; the fallback is the recovery mechanism.

## See also

- [Settings](settings) — for the rest of the settings sheet.
- [Troubleshooting](troubleshooting) — for the multi-server failure modes (a misconfigured role, a host that isn't running, etc.).
- [tech-kobold-client](tech-kobold-client) — for the `KoboldClientRegistry` and how role routing is implemented.
