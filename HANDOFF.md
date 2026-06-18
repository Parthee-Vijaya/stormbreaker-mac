# HANDOFF — Stormbreaker

> Local-first, open-source Lovable.dev/Bolt.new-klon. Native macOS (SwiftUI) app:
> chat til venstre, live web-preview (WKWebView mod lokal Vite dev-server) til højre.
> Du skriver en prompt → en AI-agent skriver et React+Vite+TS+Tailwind-projekt til disk
> → Stormbreaker kører det → preview opdaterer via HMR.

- **Sidst opdateret:** 2026-06-18
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
- `e254b02` 2026-06-18 — Multi-agent review panel: /review spins up 4 parallel agents
- `1bdd3ae` 2026-06-18 — Surface real install/build errors + slow the status quotes down
- `a30859b` 2026-06-18 — TUI polish: fun status quotes, "lokal" cost, git nested-repo fix, /copy
- `7ce7daa` 2026-06-18 — CLI onboarding: pick a model (local + cloud) on first run + friendlier errors
- `461a440` 2026-06-18 — Fix TUI crash on terminal resize (SIGWINCH handler isolation)
- `f70aa56` 2026-06-18 — Rename Forge → Stormbreaker across the codebase (command: storm)
- `d3dae9b` 2026-06-18 — docs: Avanceret CLI-side + curl-installer
- `8057d5d` 2026-06-18 — v0.3.0: website — CLI/terminal section + new features, version bump
- `5536484` 2026-06-18 — AgentLoop: keep token accounting when a build fails at artifact-close
- `41384d3` 2026-06-18 — TUI: token-forbrug altid ved siden af modelnavnet i headeren
- `36b34f0` 2026-06-18 — docs(handoff): document the agentic-SDLC køreplan (reviewer · GitHub · swarm)
- `1dc4b23` 2026-06-18 — Swarm/kø S1+S2 (agentic-SDLC borrow): task queue runner + KØ sidebar
- `799678c` 2026-06-18 — GitHub G2 (agentic-SDLC borrow): GIT sidebar section + slash commands
- `2e12ddf` 2026-06-18 — GitHub G1 (agentic-SDLC borrow): GitService + GitStatus in ForgeKit
- `4ef6e5f` 2026-06-18 — Reviewer RA3 (agentic-SDLC borrow): reviewer in the Mac app
- `c3f12fb` 2026-06-18 — Reviewer RA2 (agentic-SDLC borrow): reviewer in the CLI/TUI
- `788f696` 2026-06-17 — Reviewer RA1 (agentic-SDLC borrow): ReviewAgent core + parser
- `1d5837b` 2026-06-17 — TUI: persistent Kontekst sidebar (opencode-style)
- `1259a7a` 2026-06-17 — TUI: clearer FORGE wordmark logo (half-block font)
- `fe54620` 2026-06-17 — TUI: opencode-style redesign + first-run onboarding
<!-- COMMITLOG:END -->
