# HANDOFF — Forge

> Local-first, open-source Lovable.dev/Bolt.new-klon. Native macOS (SwiftUI) app:
> chat til venstre, live web-preview (WKWebView mod lokal Vite dev-server) til højre.
> Du skriver en prompt → en AI-agent skriver et React+Vite+TS+Tailwind-projekt til disk
> → Forge kører det → preview opdaterer via HMR.

- **Sidst opdateret:** 2026-06-15
- **Status:** Walking skeleton + **Lovable-stil UI** KOMPLET og verificeret i GUI. Empty-state hero → split-layout når der bygges; synlig tekst (tvunget lyst tema), fil-chips pr. besked, preview-toolbar (device-toggles/URL/refresh/åbn-i-browser), HMR-edits. **Multi-model**: auto-discovery af Ollama + LM Studio (verificeret live). **Kode-visning + fil-træ** (redigerbar editor → HMR) og **multi-projekt + historik** (skift/opret/slet, persistent pr. projekt) — begge verificeret live. Alle ForgeKit-tests grønne.
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
- Senere/udskudt: line-replace edits (`ModelConfig.supportsLineReplace` findes), syntax-highlighting i editor, Keychain-settings (afløser `FORGE_CLOUD_API_KEY`), MCP-eksponering, notariseret DMG, iOS companion, live NIM-cloud-test

## Commit-log (auto-genereret)

<!-- COMMITLOG:START -->
- `ec568d8` 2026-06-15 — A10: preserve scroll across HMR + recover from a blank render
- `20b3e40` 2026-06-15 — C1: line-number gutter + active-line in the code editor
- `eeef6d7` 2026-06-15 — A9: persist the dev-server console log per project
- `ff32892` 2026-06-15 — A8: reuse node_modules across projects (APFS clone cache)
- `8b43ac9` 2026-06-15 — A6: fuzz + edge tests for the streaming artifact parser
- `dc2af80` 2026-06-15 — Onboarding: richer welcome hero + fuller copy on every step
- `11b95e6` 2026-06-15 — Guided model setup in onboarding: hardware recommendation, one-click install, cloud keys
- `ef19175` 2026-06-15 — Offer the guided tour on first run (final onboarding step)
- `85f7a0a` 2026-06-15 — Turn the tutorial into an active, guided spotlight tour
- `daefb9e` 2026-06-15 — Add Forge app icon (anvil mark) + matching in-app wordmark badge
- `438c7e0` 2026-06-15 — Project management: delete/rename old projects + toggleable projects sidebar
- `24d80da` 2026-06-15 — Add a functional smoke test of the generated app (interaction-level gate)
- `83f7b88` 2026-06-15 — Extend the type-error gate to Svelte (svelte-check) and Vue (vue-tsc)
- `01ca1fc` 2026-06-15 — Catch TypeScript errors in the build loop (real tsc --noEmit gate)
- `de705cb` 2026-06-15 — Harden: parser cancel-flush, keychain, preview bridge, error cap, prompt-injection
- `3cfcead` 2026-06-15 — Harden: deploy shell-quoting, safe checkpoint restore, shell-probe timeout
- `4b3b307` 2026-06-15 — Roadmap: Supabase + multi-framework + syntax-highlight done
- `5ef3f95` 2026-06-15 — Supabase backend integration (XL)
- `83b8ea2` 2026-06-15 — Multi-framework: React, Svelte or Vue (XL)
- `b308f85` 2026-06-15 — Share live link over LAN/Tailscale
<!-- COMMITLOG:END -->
