# Stormbreaker

**Gratis, lokal app-bygger til macOS — lavet til vibecoding-nybegyndere.** Et native
SwiftUI-take på Lovable.dev / Bolt.new-mønsteret, bare med den forskel at modellen kører
på *din* Mac og koden lander på *din* disk. Skriv en prompt i almindeligt sprog; en
AI-agent skriver et rigtigt React- / Svelte- / Vue- / Next.js-projekt, installerer det,
starter dev-serveren og viser et live-preview med hot-reload.

Tanken er enkel: både **appen og de AI-modeller** du bruger er primært **open source og
gratis**, så du kan bygge til dit eget formål uden at tænke på abonnementer, API-regninger
eller skjulte omkostninger.

🔗 **Website:** [parthee-vijaya.github.io/stormbreaker-mac](https://parthee-vijaya.github.io/stormbreaker-mac/)

![Stormbreaker startskærm](docs/screenshots/01-start.png)

## Gratis hele vejen — også modellerne

De fleste vibecoding-værktøjer kører i skyen og koster penge pr. besked. Stormbreaker vender det
om: kør gratis, open-source modeller **lokalt på din egen maskine**, så der ikke er noget
der tikker op imens du lærer og eksperimenterer.

- **Gratis lokale modeller.** Kør open-source modeller som Qwen, Llama, Mistral eller Gemma
  lokalt via [Ollama](https://ollama.com) eller [LM Studio](https://lmstudio.ai). Ingen
  konto, ingen kvote, ingen regning.
- **Appen er open source.** Stormbreaker er selv open source og gratis. Hent den, kig i koden, og
  byg videre til dit eget formål — helt uden binding.
- **Cloud er valgfrit.** Vil du have en større model, kan du *valgfrit* tilføje din egen
  API-nøgle (OpenAI, Anthropic, Google Gemini, NVIDIA) — men det er aldrig nødvendigt for
  at komme i gang.

## Derfor Stormbreaker

- **Lavet til nybegyndere.** En guidet tutorial peger på hver del af appen og forklarer den
  i almindeligt sprog, og en learning-mode forklarer fagudtryk undervejs med en altid-åben
  ordbog. Du behøver ikke kunne kode.
- **Lokalt & privat.** Hele løkken — prompt → kode → preview — sker på din Mac. Dine prompts
  og din kode forlader aldrig maskinen.
- **Rigtige filer, ikke en sandkasse.** Hvert projekt er en helt almindelig mappe, du selv
  kan åbne i en editor, køre med `npm` og committe til git.
- **Native, ikke Electron.** En ægte SwiftUI-app med `WKWebView`-preview — hurtig opstart,
  lavt forbrug og rigtig macOS-opførsel.

## Installér

1. Hent den nyeste **`Stormbreaker-*.dmg`** fra
   [seneste release](https://github.com/Parthee-Vijaya/stormbreaker-mac/releases/latest).
2. Åbn DMG'en og træk **Stormbreaker** over i **Programmer**.
3. Appen er ad-hoc-signeret (endnu ikke notariseret — det venter til der er en betalt Apple
   Developer-konto), så første gang skal du **højreklik → Åbn** og bekræfte. Derefter åbner
   den normalt.

Kræver **macOS 26** (Apple Silicon). Du skal også bruge en model-backend — onboarding-guiden
hjælper dig med at installere en gratis lokal model (se [Modeller](#modeller)).

## `storm` — terminal-CLI

Hele motoren findes også som et terminal-værktøj med en fuldskærms-TUI — samme agent,
samme lokale modeller, men i din shell (godt til SSH, automatisering og dogfooding).

```sh
curl -fsSL https://parthee-vijaya.github.io/stormbreaker-mac/install.sh | bash
```

Derefter:

```sh
storm                       # åbn den interaktive TUI i den nuværende mappe
storm build "en tæller-app" # ét-skuds-build (ingen TUI)
storm new my-app --framework react
storm chat --resume         # genoptag sidste session
storm --help
```

I TUI'en skriver du `/` for kommando-menuen: `/model` (skift model midt i en session),
`/diff` `/undo` `/restore` (checkpoints), `/review` `/fix`, `/commit` `/push` `/pr` (git),
`/compact`, `/remember` `/memory`, `/theme`, `/init` (skriv `AGENTS.md`) — plus dine
**egne** kommandoer (læg en `.md` i `~/.config/storm/commands/` eller projektets
`.forge/commands/`; se [Egne kommandoer](#egne-kommandoer)).

## Sådan virker det

Stormbreaker tager dig fra en tom prompt til en app, der kører. Her er hele løkken.

### 1 · Start — beskriv hvad du vil bygge

![Startskærm](docs/screenshots/01-start.png)

Startskærmen er udgangspunktet. Skriv hvad du vil i promptfeltet ("*Hvad vil du bygge?*"),
eller vælg et udgangspunkt:

- **Build / Plan-skift** (nederst til højre i feltet) — *Build* bygger med det samme; *Plan*
  får agenten til at lægge en trinvis plan og stille opklarende spørgsmål først, før der
  skrives kode.
- **Slash-kommandoer** — skriv `/` i prompten for en hurtig menu (se trin 8 nedenfor).
- **Framework-vælger** — React, Svelte, Vue (alle Vite) eller **Next.js** (App Router).
- **Skabelon-galleri** — ét-klik-startpunkter (landingsside, dashboard, todo, portfolio,
  blog, pomodoro), så du ikke starter på en blank side.
- **Kom i gang-panel** — klon fra Git, importér en delt bundle, eller "kopiér et design fra
  et link".
- **Vedhæft** billeder/skærmbilleder eller et link, eller **diktér** prompten med stemmen.
- Den **aktive model** vises altid nederst til venstre.

### 2 · Dashboard — alle dine projekter

![Projekt-dashboard](docs/screenshots/02-dashboard.png)

Hvert build gemmes som sit eget projekt. Dashboardet viser dem som et gitter af live-
miniaturer med "sidst redigeret"-tidsstempler — klik for at fortsætte præcis hvor du slap.
Projekter kan omdøbes, eksporteres som en delbar bundle, eller slettes (med bekræftelse).

### 3 · Byg & preview — chat til venstre, live app til højre

![Live preview](docs/screenshots/03-preview.png)

Her sker arbejdet. Agenten streamer sine tanker og rettelser til venstre, mens **live-
preview'et** renderer til højre mod en lokal Vite-/Next-dev-server med hot-reload.
Preview'et har browser-agtig ramme — en rigtig URL-linje (`http://localhost:…`), genindlæs
og en størrelsesvælger. Bliv ved med at iterere i chatfeltet; hver tur gemmes som et
checkpoint, så du kan gendanne eller se forskelle. En **statusbar** nederst viser dev-
server + port, git-branch, aktiv model og projektets samlede forbrug — altid synligt.

### 4 · Kode — se alt hvad agenten skrev

![Kode-visning](docs/screenshots/04-code.png)

Skift til **Preview / Code** for at se kildekoden. Et fil-træ (kan navigeres med tastaturet)
ligger ved siden af en editor med syntaksfarvning, linjenumre og aktiv-linje-markering.
Åbne filer bliver til **faner** (skift, eller luk med ×), og et **minimap** i højre kant
giver et fugleperspektiv med klik/træk-til-scroll. Se filer blive skrevet live, kopiér en
fil, eller åbn hele projektet i din egen editor / Finder.

### 5 · Terminal — ned i skallen

![Indbygget terminal](docs/screenshots/05-terminal.png)

En indbygget terminal (`⌘T`) i projektmappen, til når du selv vil køre en kommando —
inspicér `npm`-output, tilføj en pakke, eller pille ved dev-serveren. Dev-server-logs og
JS-fejl gemmes pr. projekt, så fejl er nemme at diagnosticere.

### 6 · Deploy — sæt den online

![Deploy-menu](docs/screenshots/06-deploy.png)

Når den er klar, deploy direkte fra værktøjslinjen. Mål inkluderer **Vercel**, **Netlify**
og **GitHub Pages**, plus push til GitHub. Deploy-historik gemmes pr. projekt,
miljøvariabler i din `.env` sendes med til hosten, og du får et delbart live-link tilbage.

### 7 · Genveje — styr det fra tastaturet

![Tastaturgenveje](docs/screenshots/07-shortcuts.png)

Tryk `⌘/` for genvejsoversigten, eller `⌘K` for kommando-paletten. Alt har en genvej — nyt
projekt, indstillinger, stop generering, skift kode/preview, genindlæs, terminal — så du
sjældent skal bruge musen. Oversigten viser også slash-kommandoerne.

### 8 · Slash-kommandoer — styr prompten fra tastaturet

![Slash-kommandoer](docs/screenshots/08-slash.png)

Skriv `/` i prompten for en menu (↑/↓ for at flytte, Enter eller Tab for at vælge, Esc for
at lukke). Både danske og engelske aliasser virker:

- `/byg` · `/build` og `/plan` · `/planlæg` skifter agentens tilstand (anvendes også inline
  når du skriver kommandoen + mellemrum, fx "`/plan `").
- `/ret` · `/fix`, `/stil` · `/style`, `/mobil` · `/responsive` og `/forklar` · `/explain`
  udfylder en færdig prompt, så du kan affyre en almindelig anmodning med få tastetryk.

### 9 · Guidet tutorial — lær vibecoding undervejs

![Guidet tutorial](docs/screenshots/09-tutorial.png)

Ny i det her? **Start tutorial** (i startskærmens sidebar) kører en spotlight-gennemgang,
der peger på hver del af appen og forklarer den i almindeligt sprog — hvad en *prompt* er,
*Build vs Plan*, hvor koden og preview'et bor. Sammen med **learning-mode** (en kontakt i
Indstillinger) viser Stormbreaker forklaringskort ved milepæle (første build, en auto-rettelse,
første deploy) og holder en altid-åben ordbog over fagudtrykkene.

## Alt i kassen

**Agent & motor**
- Streaming-parser med line-replace / diff-rettelser (ikke kun hele filer).
- Selv-rettende agent-løkke: kører `tsc --noEmit` + en funktionel røgtest og retter sine
  egne type-/build-fejl, før den afleverer.
- Smart kontekst-styring + et model-initieret *read-file*-værktøj, så agenten kan inspicere
  det projekt den redigerer.
- Checkpoint pr. tur (skygge-git) med gendan & diff.
- Spørg-om-koden (read-only RAG) — stil spørgsmål om det genererede projekt.
- Pluggbare agent-backends og en **MCP-server** (`storm-mcp`) der eksponerer et projekt til
  eksterne agenter.
- **Værktøjer agenten selv kan bruge:** web-søgning/-hentning, kode-søgning (`grep` i
  indhold + `glob` på filnavne), read-file, og eksterne **MCP**-værktøjer — alle som
  tool-runder hvor resultatet fødes tilbage (og altid behandlet som * utroværdig* tekst).
- **Live todo-checkliste** under en build, automatisk samtale-**compaction** ved lange
  sessioner, og **cross-session-hukommelse** (`/remember`, auto-udtræk af holdbare fakta).
- **Sikkerhed:** per-kommando shell-triage (sikkert dev-værktøj kører frit; `rm -rf /`,
  pipe-to-shell o.l. afvises; resten spørger), write-jail mod symlink-escape, SSRF-værn på
  web-hentning, og bekræftelse før et projekts MCP-servere startes.
- **Projekt-regler:** læser `CLAUDE.md` / `AGENTS.md` / `AI_RULES.md`, så et projekt lavet
  til Claude Code eller opencode virker uændret.

**`storm` CLI (terminal)**
- Fuldskærms-TUI (håndbygget, nul-dependency): live fil-streaming med syntaks-farver,
  farvede diffs, statuslinje, slash-menu, temaer.
- Egne slash-kommandoer (`$ARGUMENTS` / `` !`shell` `` / `@fil`), session-resume,
  model-skift midt i en session, indbygget reviewer + git + opgave-kø.
- Samme 7 providere som appen; `--plain`/`--no-tui` for CI og scripts.

**Workflow**
- Flere frameworks: React / Svelte / Vue (Vite) + **Next.js** (App Router).
- Skabeloner, Git-klon, design-fra-link, og import/eksport af delbare projekt-bundles.
- Visuel redigering, "skift stil/palette"-injektion, og en UI til at tilføje/fjerne
  npm-pakker.
- Kommando-palette, fuld tastatur-oversigt, stemme-diktering (CanaryKit), toasts,
  forbrugs-tæller.
- Plan-mode med strukturerede opfølgende spørgsmål, før der skrives kode.

**Platform**
- Native SwiftUI + `WKWebView`; genbrugt WebView + proces-pool for hurtig opstart.
- Lyst / mørkt (Midnat) tema med et motion-sprog af diskrete mikro-interaktioner.
- **Statusbar** i VS Code-stil (dev-server/port, git-branch, aktiv model, forbrug),
  **editor-faner** og et **minimap**.
- Justerbare, vedvarende paneler.
- Native macOS-notifikationer (build færdig / deploy live / fejlet) når appen er i baggrunden.
- Valgfri HTTP-status-server til at parre med en iOS-companion.

## Modeller

Stormbreaker taler med det du har kørende. Onboarding-guiden registrerer din hardware, anbefaler en
lokal kode-model til din RAM-størrelse, og kan installere **Ollama** eller **LM Studio** for
dig (officiel download eller Homebrew) og hente den anbefalede model.

- **Lokalt (gratis, privat):** Ollama eller LM Studio. Lokale modeller kaldes via det native
  chat-endpoint, så kontekst-vinduet (`num_ctx`) sættes korrekt i stedet for at blive
  stiltiende afkortet.
- **Cloud (medbring en API-nøgle):** OpenAI, Anthropic, **Google Gemini** (har et gratis
  niveau) eller NVIDIA NIM. Hver udbyder har et ét-klik "hent en API-nøgle"-link i
  indstillinger. Bemærk: det er en **API-nøgle** fra udbyderens konsol — målt forbrug, og
  adskilt fra et evt. chat-abonnement. Aldrig nødvendigt for at komme i gang.

Nøgler gemmes i macOS Keychain, aldrig i klartekst.

## Egne kommandoer

Lav genbrugelige slash-kommandoer som markdown-filer — globalt i
`~/.config/storm/commands/` eller pr. projekt i `.forge/commands/`. Filnavnet bliver
kommandoens navn. Eksempel `~/.config/storm/commands/review.md`:

```markdown
---
description: Gennemgå ændringerne for fejl
mode: plan
---
Gennemgå denne diff grundigt for fejl og sikkerhedsproblemer:

!`git diff`

Fokusér især på: $ARGUMENTS
```

Kør den med `/review auth-flowet`. Skabelonen udvides før den sendes: `$ARGUMENTS` bliver
til din tekst, `` !`shell` `` indsætter en kommandos output (kun sikre kommandoer kører),
og `@sti/fil` indsætter en projektfils indhold. Inspireret af opencode — samme idé,
Stormbreaker-motoren.

## Tilpasning (config-filer)

Alt er filbaseret — globalt i `~/.config/storm/` eller pr. projekt i `.forge/`:

| Fil | Hvad |
|-----|------|
| `commands/*.md` | Egne slash-kommandoer (se ovenfor). |
| `permissions.json` | Tilladelser oven på den indbyggede triage: `{"deny":["git push*"],"allow":["docker *"],"ask":["npm run deploy*"]}`. Katastrofale kommandoer (`rm -rf /`, `curl\|sh`) kan **aldrig** løsnes op. |
| `themes/*.json` | Egne farvetemaer (`{"name":"Solaris","bg":"#002b36","accent":"#b58900",…}`); vises i `/theme`. `system` følger terminalens farver. |
| `.mcp.json` | MCP-servere — lokale (`command`) **og** remote (`url` + `headers` over HTTP/SSE), med `enabled`. Bekræftes før de starter. |
| `.forge/instructions.json` | Ekstra regel-filer ud over `CLAUDE.md`/`AGENTS.md`/`AI_RULES.md` (fx `["docs/STYLE.md"]`). |

I TUI'en kan du desuden `/paste` et billede fra udklipsholderen (screenshot → UI med en
vision-model), `/model` skifte model, og `/theme` skifte tema midt i en session.

## Som sub-agent i en agent-platform (MCP)

Stormbreaker forbliver en native Swift-app — og kobler ind i en større agent-platform
(fx **LangChain/deepagents**) som en specialiseret **sub-agent** over MCP. `storm-mcp`
(installeres sammen med `storm`) eksponerer projektet som værktøjer: `list_files`,
`read_file`, `write_file`, `run_command`, `get_errors` — og **`build`**, der afleverer et
*helt* build til Stormbreakers egen selv-rettende agent og giver et resumé retur.

Så en deepagents "deep agent" (Python) kan sige *"byg mig den her app"*, og
Stormbreaker gør det native nedenunder — ét kontrolplan, ingen omskrivning. Hele
opskriften: **[docs/deepagents-integration.md](docs/deepagents-integration.md)**.

## Byg fra kildekode

```sh
# Motor (ren Foundation Swift-pakke — Command Line Tools er nok til at bygge)
cd StormbreakerKit && swift build

# StormbreakerKit-tests kræver den fulde Xcode-toolchain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Generér app-projektet (Stormbreaker.xcodeproj er gitignored — regenerér efter pull)
xcodegen generate

# Byg macOS-appen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Stormbreaker.xcodeproj -scheme Stormbreaker -arch arm64 \
    ONLY_ACTIVE_ARCH=YES -derivedDataPath ./.build-xcode build

# Pak en Release-DMG (læser MARKETING_VERSION → Stormbreaker-<version>.dmg)
bash scripts/build-dmg.sh
```

Kør `xcodegen generate` når der tilføjes nye filer til **Stormbreaker**-app-targetet. StormbreakerKit-kilder
glob'es af SPM, så nye filer dér kræver ikke en regenerering.

## Struktur

- **`StormbreakerKit/`** — motoren (Swift-pakke, ren Foundation, Swift 6 strict concurrency):
  model-router, streaming-parser, action-executor, proces-/dev-server-manager, agent-løkke.
  Indeholder også **`storm`** (terminal-CLI + TUI) og `storm-mcp` (MCP stdio-server).
  Bygger og testes headless.
- **`Stormbreaker/`** — SwiftUI macOS-appen: chat-panel, kode-editor, `WKWebView`-preview, terminal,
  onboarding, indstillinger. Genereres til `Stormbreaker.xcodeproj` via `xcodegen`.
- **`docs/`** — denne sides screenshots + GitHub Pages-landingssiden (`index.html`).
- **`scripts/`** — `build-dmg.sh` m.fl.

## Status & forbehold

Stormbreaker er et aktivt personligt projekt, feature-komplet gennem sin P2-backlog. Kendte
begrænsninger:

- **Ikke notariseret endnu.** Ad-hoc-signeret; første start kræver højreklik → Åbn.
  Notarisering venter til der er en betalt Apple Developer-konto.
- **Kun Apple Silicon / macOS 26.**
- Cloud-deploy (Vercel/Netlify) kræver at deres respektive CLI'er er installeret og logget ind.
- iOS-companion er kun host-side indtil videre (en HTTP-status-server + menu-kontakt); selve
  iOS-appen er et separat, igangværende target.

Se [HANDOFF.md](HANDOFF.md) og [ROADMAP.md](ROADMAP.md) for fulde stack-noter, faldgruber og
backlog.
