# HANDOFF — Stormbreaker

> Local-first, open-source Lovable.dev/Bolt.new-klon. Native macOS (SwiftUI) app:
> chat til venstre, live web-preview (WKWebView mod lokal Vite dev-server) til højre.
> Du skriver en prompt → en AI-agent skriver et React+Vite+TS+Tailwind-projekt til disk
> → Stormbreaker kører det → preview opdaterer via HMR.

- **Sidst opdateret:** 2026-06-20
- **Status:** Walking skeleton + **Lovable-stil UI** KOMPLET og verificeret i GUI. Empty-state hero → split-layout når der bygges; synlig tekst (tvunget lyst tema), fil-chips pr. besked, preview-toolbar (device-toggles/URL/refresh/åbn-i-browser), HMR-edits. **Multi-model**: auto-discovery af Ollama + LM Studio (verificeret live). **Kode-visning + fil-træ** (redigerbar editor → HMR) og **multi-projekt + historik** (skift/opret/slet, persistent pr. projekt) — begge verificeret live. **nanocoder-køreplan leveret**: `storm` CLI, bruger-skills (CLI+GUI), og MCP tool-calling — agenten kan kalde eksterne MCP-værktøjer midt i et build (e2e-verificeret) + eksterne agenter kan drive Stormbreaker via `storm-mcp`. **opencode-køreplan leveret**: approval-gate, diagnostics, cost, AGENTS.md, @file, export, prettier, steer-API + **fuld-skærms TUI** (`storm chat`) med live fil-streaming, farvediffs, model-skift, sessioner, slash-menu/temaer og en Kontekst-sidebar. **agentic-SDLC leveret**: reviewer-agent, GitHub-integration (GIT-sidebar + `/github`/`/push`/`/pull`/`/pr`) og swarm/kø (`/kø` + KØ-sidebar). Alle 177 StormbreakerKit-tests grønne; Mac-app + CLI bygger.
- **Branch:** main · committed: skeleton + Lovable-UI + LM Studio-discovery (intet remote endnu)

## Stack

| Lag | Teknologi |
|-----|-----------|
| App-shell | SwiftUI (macOS 26), WKWebView via NSViewRepresentable |
| Motor | StormbreakerKit — Swift Package (macOS 14+), ren Foundation, Swift 6 strict concurrency |
| Proces | Foundation `Process` + `Pipe.readabilityHandler` → `AsyncStream` |
| Modeller | Auto-discovery: Ollama native `/api/chat` (num_ctx) + LM Studio `/v1` (OpenAI-kompat) + NVIDIA NIM/OpenAI/Anthropic. Grupperet vælger m/ refresh; embeddings filtreres fra |
| Genereret app | React + Vite + TypeScript + Tailwind v4 (baked-in template) |
| Distribution | Developer ID + Hardened Runtime, INGEN sandbox, notariseret DMG |

## Kør / byg / test

```sh
# StormbreakerKit (motoren): `swift build` virker under CommandLineTools, men TESTS
# kræver Xcode-toolchainen (XCTest/Testing følger kun med fuld Xcode):
cd StormbreakerKit && swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip DevServerIntegrationTests
# Fuld end-to-end (rigtig npm install + vite):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer STORM_RUN_INTEGRATION=1 \
  swift test --filter DevServerIntegrationTests

# App-target — kræver fuld Xcode (ikke CommandLineTools)
xcodegen generate                       # genererer Stormbreaker.xcodeproj fra project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Stormbreaker.xcodeproj -scheme Stormbreaker build

# Live-modeltest kræver kørende Ollama med qwen2.5-coder:14b
ollama list | grep qwen2.5-coder
```

## Gotchas

- **Ollama `/v1` kan IKKE sætte num_ctx** → trunkerer stille ved ~2-4k. Brug native `/api/chat` + `options.num_ctx`.
- **Ny SwiftUI `WebView`/`WebPage` mangler `WKScriptMessageHandler`** → vi bruger `WKWebView` (NSViewRepresentable) for JS-broen.
- **App Sandbox dræber node-child** (library validation på native addons) → Developer ID uden sandbox.
- **GUI-apps arver ikke shell-PATH** → `NodeResolver` finder node via login-shell-probe + kendte stier (`/opt/homebrew/bin`).
- **`URLSession.AsyncBytes.lines` dropper tomme linjer** → ødelægger SSE-framing; brug `SSELineReader`.
- **xcodebuild kræver fuld Xcode** — `xcode-select` peger pt. på CommandLineTools. Brug `DEVELOPER_DIR=...` foran xcodebuild (ingen sudo), eller `sudo xcode-select -s /Applications/Xcode.app`.
- **App tvinger lyst tema** (`.preferredColorScheme(.light)` + eksplicitte `Theme`-farver) — ellers blev tekst usynlig i system-dark-mode. Brug ALDRIG `.primary`/`.secondary` i app-laget; brug `Theme.ink`/`inkSoft`.
- **Nye SwiftUI-filer kræver `xcodegen generate`** før de er med i builden (project.yml indekserer mappen ved generering).
- **Build kun aktiv arch**: `-arch arm64 ONLY_ACTIVE_ARCH=YES` (universal-build fejler på SwiftPM-modul-resolution). Byg via `-scheme Stormbreaker` (ikke `-target`) så pakke-produkter linkes.
- **Kode-editoren MÅ ikke smart-quote** — SwiftUI `TextEditor` laver `"` om til krøllede `"` og ødelægger JSX. Brug `NSTextView` (NSViewRepresentable, `CodeTextView`) med `isAutomaticQuoteSubstitutionEnabled=false` + dash/text-replacement/spelling/grammar off.

## Status pr. fase (alle leveret + verificeret)

- ✅ Fase A: skelet + git/konventioner + xcodegen project.yml
- ✅ Fase B: proces/dev-server-lag + baked-in template — integrationstest mod RIGTIG npm/vite
- ✅ Fase D: modelrouter + 3 providers — Ollama native /api/chat live-testet (num_ctx fix)
- ✅ Fase E: streaming artifact-parser (tegn-for-tegn robust) + executor + markdown-fence-stripping
- ✅ Fase F(motor): agent-loop + self-correction (clean / repair ≤3 / no-progress guard)
- ✅ Fase C: SwiftUI app-shell + WKWebView JS-bro (onerror/console.error/unhandledrejection)
- ✅ Fase F(UI): xcodebuild grøn + end-to-end GUI — Todo-app renderede live, HMR-edit virkede, ingen orphan-vite ved quit

## Roadmap (efter skelet) — brugeren valgte 4 features, bygges i rækkefølge

- ✅ Feature 1: Kode-visning + fil-træ (redigerbar `CodeTextView`, autosave→HMR) — verificeret live
- ✅ Feature 2: Multi-projekt + historik (skift/opret/slet, persistent chat + kode pr. projekt) — verificeret live
- ✅ Feature 3: Deploy GitHub + Vercel (git→`gh repo create`→`vercel deploy --prod`, status-panel m/ links). UI + CLI-auth (gh=Parthee-Vijaya, vercel=parthee-vijaya) verificeret; selve deploy = bruger-trigget klik (udadvendt handling). Respekterer ALDRIG-disable-deployment-protection.
- ✅ Feature 4: Visuel redigering — select-tilstand → klik element i preview (JS-bro fanger tag/tekst/klasser) → beskriv ændring i composer → targeted prompt til agent-loop → retter kilde → HMR. Verificeret live: h1 "Stormbreaker Todo App" → "My Tasks" i blåt.
- Senere/udskudt: line-replace edits (`ModelConfig.supportsLineReplace` findes), syntax-highlighting i editor, Keychain-settings (afløser `STORM_CLOUD_API_KEY`), native function-calling for cloud-modeller (XML forbliver lokal default), approval-gate for shell-actions, notariseret DMG (afventer Apple Developer-konto), live NIM-cloud-test

## nanocoder-køreplan (CLI · Skills · MCP) — alle tre leveret

- ✅ Fase 1 — `storm` CLI: subkommandoer new/build/chat/skills/mcp, `~/.config/forge/config.json`, flag `--plain`/`--no-serve`/`--plan`/`--skill`/`--provider`/`--model`. Genbruger dogfood-wiringen; bygger under CLT (`swift run storm`).
- ✅ Fase 2 — Skills: markdown + `---` frontmatter, projekt `.forge/skills/` + global `~/.config/forge/skills/` + 6 builtins (precedence projekt>global>builtin). Eksponeret i CLI + GUI-composerens `/`-menu. 8 tests.
- ✅ Fase 3 — MCP / tool-calling:
  - **Server** (`storm-mcp`): list_files/read_file/write_file/run_command/get_errors — eksterne agenter (Claude Code, Cline, nanocoder) kan drive en Stormbreaker-projekt.
  - **Klient** (`MCPClient` + `MCPManager`): læser nanocoder-kompatibel `.forge/.mcp.json` (`${ENV}`-expansion), starter servere, aggregerer værktøjer.
  - **Agent-integration**: modellen kalder et værktøj med `<forgeAction type="mcp" server tool>{args}` (SKAL ligge i en `<forgeArtifact>`) → tool-round i AgentLoop (≤5, tæller ikke som repair) → resultatet fodres tilbage via `mcpResultTurn`. Virker i både CLI og GUI. E2e-verificeret med qwen3.6 + en throwaway MCP-server (modellen hentede en uggætbar kode og brugte den i den byggede side).

## agentic-SDLC-køreplan (reviewer · GitHub · swarm) — leveret
Borrow fra scalable.dk/agentic-sdlc — gør Stormbreaker til et lille team, ikke kun én agent.

- ✅ **Reviewer-agent (RA1–RA3):** efter et rent build gennemgår en 2. agent (plan-modellen) diff'en for korrekthed/sikkerhed/tilgængelighed. Rådgivende — blokerer aldrig. `ReviewAgent` i StormbreakerKit parser `SEVERITY :: KATEGORI :: FIL :: BESKED`; vises i TUI-transcript + REVIEW-sidebar (`/review`, `/fix`) og i GUI som et kort (Ret det/Afvis). Slå til/fra i Settings (`reviewOnBuild`).
- ✅ **GitHub (G1–G2):** `GitService` (StormbreakerKit) styrer projektets RIGTIGE `.git` + `gh` — adskilt fra checkpoint-skyggerepoet. `GitStatus` (isRepo/branch/remote/↑↓/dirty/openPR) vises i en **GIT-sektion i Kontekst-sidebaren** (5 tilstande: ikke-repo → fuldt synk). Kommandoer `/github [navn] [public]` (privat som standard), `/commit`, `/push`, `/pull --rebase`, `/pr` (laver `storm/<slug>`-branch hvis på main). 13 unit-tests. Probe-formater verificeret mod stormbreaker-mac-repoet.
- ✅ **Swarm/kø (S1–S2):** sekventiel byggekø (swarm-lite — ét projekt = én build ad gangen, ellers fil-konflikter). `/kø <opgave>` stiller i kø + starter hvis ledig; drainer én ad gangen, build+review pr. task før næste. **Pause ved fejl** (køede tasks bygger oftest videre på forrige → fejl kaskaderer ellers); `/kø` genoptager, `/kø ryd` rydder. **KØ-sidebar-sektion** med live-status ⋯ kø · ⟳ bygger · ◎ review · ✓ færdig · ✗ fejl. Verificeret live på qwen3.6 (tmux): empty → 3 i kø → "✓ A / ⟳ B / ⋯ C" drainer korrekt.

## Commit-log (auto-genereret)

<!-- COMMITLOG:START -->
- `f5d6c6c` 2026-06-20 — docs: customization config files + 4 new parity features
- `389ab3b` 2026-06-20 — Parity: remote MCP servers over HTTP/SSE + enabled flag
- `407eedf` 2026-06-20 — Parity: /paste a clipboard image into the TUI (vision)
- `c87ee10` 2026-06-20 — Parity: custom JSON themes + instructions[] extra rule files
- `418c38b` 2026-06-20 — Parity: user-configurable shell permissions overlay
- `08135e1` 2026-06-20 — docs(site): new features on GitHub Pages + custom-commands screenshot
- `f43b2fb` 2026-06-20 — docs: README covers the storm CLI, curl-install, and new agent tools
- `04cfdca` 2026-06-20 — Parity: grep/glob code-search tools for the agent
- `6cc535f` 2026-06-20 — Parity: read CLAUDE.md as a project rules file
- `65a4fb8` 2026-06-20 — Parity: custom slash commands (opencode)
- `cb9c4a5` 2026-06-20 — Fix: tighten orphan-reclaim match (drop bare "node")
- `41fc71e` 2026-06-20 — Fix: ProcessRunner doesn't leak pumps/pipes when launch fails
- `d499e81` 2026-06-20 — Fix: search-query encoding, github host check, gemini-2.5 pricing
- `a438c6a` 2026-06-20 — Fix: stream watchdog for Anthropic + per-request MCP timeout
- `5078430` 2026-06-20 — Fix: flush never re-runs a command after a mid-batch throw
- `a011a98` 2026-06-20 — Fix: cap pinned @file size so it can't overflow num_ctx
- `ab29a57` 2026-06-20 — Fix: don't truncate a tag at a '>' inside a quoted attribute
- `afa59f2` 2026-06-20 — Fix: stripCodeFence never empties a file (data-loss guard)
- `7df7b9b` 2026-06-20 — Fix: surface in-band provider errors instead of an empty turn
- `7f28f04` 2026-06-19 — Fix: kill the whole dev-server subtree on stop, not one level
<!-- COMMITLOG:END -->
