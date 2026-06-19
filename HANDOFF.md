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
- `afa59f2` 2026-06-20 — Fix: stripCodeFence never empties a file (data-loss guard)
- `7df7b9b` 2026-06-20 — Fix: surface in-band provider errors instead of an empty turn
- `7f28f04` 2026-06-19 — Fix: kill the whole dev-server subtree on stop, not one level
- `0a4faf2` 2026-06-19 — Fix: never send an empty assistant message to a provider
- `4a911f6` 2026-06-19 — Fix: apply --base-url to cloud providers, not just ollama/lmStudio
- `caa8ed5` 2026-06-19 — Fix: enable + handle bracketed paste in the TUI
- `20a3507` 2026-06-19 — Security: untrusted-content boundary on file/MCP/error turns
- `4172305` 2026-06-19 — Security (H3): resolve symlinks before the write-jail containment check
- `07ef1d4` 2026-06-19 — Security (H2): SSRF guard on all outbound web requests
- `a5e3faf` 2026-06-19 — Security (C6): confirm before launching project-local MCP servers
- `090a845` 2026-06-19 — Security: harden ShellRules against RCE + secret exfiltration
- `056edcb` 2026-06-19 — Recursive folder listing so nested files (e.g. public/*.jpeg) show
- `69453d4` 2026-06-19 — Read user-referenced local paths for real (+ browser open); stop faking it
- `94174fd` 2026-06-19 — Bare `storm` launches the chat TUI (+ `stormbreaker` alias)
- `bebc14e` 2026-06-19 — docs(site): current features + commands + fresh storm-branded CLI screenshots
- `b3a041b` 2026-06-18 — docs: add CLI architecture slide deck (.pptx) + generator
- `81ce686` 2026-06-18 — docs: thorough CLI architecture doc with diagrams
- `a20cb42` 2026-06-18 — Cross-session memory: storm now remembers the user + project between sessions
- `bb4be3d` 2026-06-18 — Conversation compaction: summarize old turns so local context windows don't overflow
- `6d1d357` 2026-06-18 — Live plan checklist (todowrite): show the agent's plan as a checklist during a build
<!-- COMMITLOG:END -->
