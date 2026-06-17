# HANDOFF — Forge

> Local-first, open-source Lovable.dev/Bolt.new-klon. Native macOS (SwiftUI) app:
> chat til venstre, live web-preview (WKWebView mod lokal Vite dev-server) til højre.
> Du skriver en prompt → en AI-agent skriver et React+Vite+TS+Tailwind-projekt til disk
> → Forge kører det → preview opdaterer via HMR.

- **Sidst opdateret:** 2026-06-17
- **Status:** Walking skeleton + **Lovable-stil UI** KOMPLET og verificeret i GUI. Empty-state hero → split-layout når der bygges; synlig tekst (tvunget lyst tema), fil-chips pr. besked, preview-toolbar (device-toggles/URL/refresh/åbn-i-browser), HMR-edits. **Multi-model**: auto-discovery af Ollama + LM Studio (verificeret live). **Kode-visning + fil-træ** (redigerbar editor → HMR) og **multi-projekt + historik** (skift/opret/slet, persistent pr. projekt) — begge verificeret live. **nanocoder-køreplan leveret**: `forge` CLI, bruger-skills (CLI+GUI), og MCP tool-calling — agenten kan kalde eksterne MCP-værktøjer midt i et build (e2e-verificeret) + eksterne agenter kan drive Forge via `forge-mcp`. Alle 112 ForgeKit-tests grønne; Mac-app + CLI bygger.
- **Branch:** main · committed: skeleton + Lovable-UI + LM Studio-discovery (intet remote endnu)

## Stack

| Lag | Teknologi |
|-----|-----------|
| App-shell | SwiftUI (macOS 26), WKWebView via NSViewRepresentable |
| Motor | ForgeKit — Swift Package (macOS 14+), ren Foundation, Swift 6 strict concurrency |
| Proces | Foundation `Process` + `Pipe.readabilityHandler` → `AsyncStream` |
| Modeller | Auto-discovery: Ollama native `/api/chat` (num_ctx) + LM Studio `/v1` (OpenAI-kompat) + NVIDIA NIM/OpenAI/Anthropic. Grupperet vælger m/ refresh; embeddings filtreres fra |
| Genereret app | React + Vite + TypeScript + Tailwind v4 (baked-in template) |
| Distribution | Developer ID + Hardened Runtime, INGEN sandbox, notariseret DMG |

## Kør / byg / test

```sh
# ForgeKit (motoren): `swift build` virker under CommandLineTools, men TESTS
# kræver Xcode-toolchainen (XCTest/Testing følger kun med fuld Xcode):
cd ForgeKit && swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip DevServerIntegrationTests
# Fuld end-to-end (rigtig npm install + vite):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FORGE_RUN_INTEGRATION=1 \
  swift test --filter DevServerIntegrationTests

# App-target — kræver fuld Xcode (ikke CommandLineTools)
xcodegen generate                       # genererer Forge.xcodeproj fra project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Forge.xcodeproj -scheme Forge build

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
- **Build kun aktiv arch**: `-arch arm64 ONLY_ACTIVE_ARCH=YES` (universal-build fejler på SwiftPM-modul-resolution). Byg via `-scheme Forge` (ikke `-target`) så pakke-produkter linkes.
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
- ✅ Feature 4: Visuel redigering — select-tilstand → klik element i preview (JS-bro fanger tag/tekst/klasser) → beskriv ændring i composer → targeted prompt til agent-loop → retter kilde → HMR. Verificeret live: h1 "Forge Todo App" → "My Tasks" i blåt.
- Senere/udskudt: line-replace edits (`ModelConfig.supportsLineReplace` findes), syntax-highlighting i editor, Keychain-settings (afløser `FORGE_CLOUD_API_KEY`), native function-calling for cloud-modeller (XML forbliver lokal default), approval-gate for shell-actions, notariseret DMG (afventer Apple Developer-konto), live NIM-cloud-test

## nanocoder-køreplan (CLI · Skills · MCP) — alle tre leveret

- ✅ Fase 1 — `forge` CLI: subkommandoer new/build/chat/skills/mcp, `~/.config/forge/config.json`, flag `--plain`/`--no-serve`/`--plan`/`--skill`/`--provider`/`--model`. Genbruger dogfood-wiringen; bygger under CLT (`swift run forge`).
- ✅ Fase 2 — Skills: markdown + `---` frontmatter, projekt `.forge/skills/` + global `~/.config/forge/skills/` + 6 builtins (precedence projekt>global>builtin). Eksponeret i CLI + GUI-composerens `/`-menu. 8 tests.
- ✅ Fase 3 — MCP / tool-calling:
  - **Server** (`forge-mcp`): list_files/read_file/write_file/run_command/get_errors — eksterne agenter (Claude Code, Cline, nanocoder) kan drive en Forge-projekt.
  - **Klient** (`MCPClient` + `MCPManager`): læser nanocoder-kompatibel `.forge/.mcp.json` (`${ENV}`-expansion), starter servere, aggregerer værktøjer.
  - **Agent-integration**: modellen kalder et værktøj med `<forgeAction type="mcp" server tool>{args}` (SKAL ligge i en `<forgeArtifact>`) → tool-round i AgentLoop (≤5, tæller ikke som repair) → resultatet fodres tilbage via `mcpResultTurn`. Virker i både CLI og GUI. E2e-verificeret med qwen3.6 + en throwaway MCP-server (modellen hentede en uggætbar kode og brugte den i den byggede side).

## Commit-log (auto-genereret)

<!-- COMMITLOG:START -->
- `f44a92a` 2026-06-17 — TUI P7 (opencode/nanocoder): ANSITheme + CheckpointManager in the CLI engine
- `79e843c` 2026-06-17 — TUI P6 (opencode/nanocoder): wire the real AgentLoop + permission modal
- `4ef787e` 2026-06-17 — TUI P5 (opencode/nanocoder): full-screen event loop
- `64a562c` 2026-06-17 — TUI P4 (opencode/nanocoder): input decoder
- `9d9bc7c` 2026-06-17 — TUI P3 (opencode/nanocoder): layout solver + Forge screen skeleton
- `64f4be1` 2026-06-17 — TUI P2 (opencode/nanocoder): pure render core in ForgeKit
- `491153e` 2026-06-17 — TUI P1 (opencode/nanocoder): terminal lifecycle + guaranteed teardown
- `6c4a8dd` 2026-06-17 — docs(handoff): opdater commit-log
- `4559bd3` 2026-06-17 — Fase 4c (opencode): steer-API — styr Forge fra iPhone/curl
- `43801d7` 2026-06-17 — Fase 4b (opencode): prettier-ved-gem (opt-in)
- `982cbc1` 2026-06-17 — Fase 4a (opencode): markdown chat-eksport
- `8702e9a` 2026-06-17 — Fase 3 (opencode): AGENTS.md-interop + @file-mentions
- `b6e3ea2` 2026-06-17 — Fase 2a (opencode): editor-diagnostics (tsc squiggles)
- `c0dc38b` 2026-06-17 — Fase 2b (opencode): cost-tracking (kr/$) på metrics
- `9829233` 2026-06-17 — Fase 1b (opencode): approval-gate — GUI
- `09bd6e2` 2026-06-17 — Fase 1a (opencode): approval-gate — motor + CLI
- `445852d` 2026-06-17 — docs(handoff): opdater commit-log
- `7a35e83` 2026-06-17 — fix(engine): hæv max output-tokens 8k → 16k
- `10a7ced` 2026-06-17 — docs(handoff): opdater commit-log
- `0ffcd2b` 2026-06-17 — feat(metrics): vis metrics pr. besked direkte i chatten
<!-- COMMITLOG:END -->
