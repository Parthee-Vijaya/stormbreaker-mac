# Forge — Roadmap

> Gennemtænkt plan for videreudvikling. Forankret i den faktiske kodebase
> (ForgeKit-motoren + SwiftUI-appen). 20 forbedringer, 20 nye features, 20
> design-forslag, og en faseinddelt implementeringsplan til sidst.

**Nuværende stade (baseline):** Walking skeleton + Lovable-stil UI, multi-model
(Ollama + LM Studio + cloud), kode-visning/fil-træ, multi-projekt + historik,
deploy (GitHub + Vercel), visuel redigering. Default whole-file writes,
qwen2.5-coder:14b lokalt.

**Legende** — Effort: **S** <½ dag · **M** 1–2 dage · **L** 3–5 dage · **XL** uge+ ·
Prioritet: **P0** (gør først) · **P1** · **P2** (nice-to-have).

---

## 0. ONBOARDING & KONFIGURATION (first-run)

**Mål:** Første gang appen åbnes (ingen `preferences.json`) kører en kort wizard
der sætter Forge op og skriver et `Preferences`-objekt. Alt kan ændres bagefter i
Settings (⌘,). Hvert trin har Tilbage/Næste; valgfrie trin har "Spring over";
lukkes wizard'en, bruges fornuftige defaults.

**Persistens:** `Preferences: Codable` i `~/Library/Application Support/Forge/preferences.json`
via en ny `PreferencesStore` (**A22**). Cloud-nøgler i **Keychain** (**A4**).
`AppModel.init` læser `Preferences`; mangler den → vis `OnboardingView` (**C10**).

**Trin (kort-sekvens i ét vindue):**

0. **Velkomst** — Forge-wordmark + kort pitch → "Kom i gang".
1. **Dit navn** — "Hvad skal vi kalde dig?" Default = `NSFullUserName()`. → `Preferences.userName`. Bruges i UI ("Hej Parthee") + injiceres i system-prompten så agenten tiltaler dig rigtigt. *(→ B21)*
2. **Projekt-placering** — folder-picker. Defaults: App Support (anbefalet) eller `~/Desktop/Claude/projekter/aktive`. → `Preferences.projectsRoot`; `ProjectStore.root` læser den. *(→ A21)*
3. **Model** — kør `ModelDiscovery`; vis lokale (Ollama/LM Studio, grupperet) + cloud; vælg default. Tomt? → hjælp til at starte Ollama/LM Studio + "Prøv igen". → `Preferences.defaultModelID`.
4. **Cloud-nøgle (valgfri)** — provider (NVIDIA NIM / OpenAI / Anthropic) + nøgle-felt + "Spring over". → Keychain. *(→ A4)*
5. **GitHub** — `gh auth status`: logget ind → vis konto + vælg owner/org (`gh api user`, `/user/orgs`); ellers "Log ind" (åbner `gh auth login --web`) + "Spring over". → `Preferences.githubOwner`. *(→ B23 + Feature 3)*
6. **Vercel (valgfri)** — `vercel whoami` → vis konto + team-scope (`vercel teams ls`); "Spring over". → `Preferences.vercelScope`. *(→ B23)*
7. **Global memory** — fritekst: "Hvad skal Forge altid huske om dig?" (fx "TypeScript strict, minimale deps, sort/hvid UI, dansk UI-tekst"). → `Preferences.memory`; injiceres i HVER system-prompt. *(→ B21)*
8. **Standard `AI_RULES.md`** — redigerbar skabelon (fornuftig default) som hvert NYT projekt får i roden + injiceres i dets prompt + committes/deployes med projektet. → `Preferences.defaultRulesTemplate`. *(→ B22)*
9. **Færdig** — opsummering → "Byg dit første projekt" → empty-state.

**Agent-integration (det der får navn + memory + regler til at virke):**
`MessageBuilder.build` komponerer system-beskeden som
`SystemPrompt.forge` + (navn → "The user is called …") + (global memory → "User preferences: …")
+ (projektets `AI_RULES.md` hvis den findes). Sådan flyder bruger-præferencer +
projekt-regler ind i hver tur uden ekstra arbejde.

**Settings (⌘,):** samme felter som wizard'en, så alt kan redigeres bagefter
(navn, placering, default-model, nøgler, GitHub-owner, Vercel-scope, memory, AI_RULES-skabelon).

**Implementeringsrækkefølge:** A22 → A4 → B21/B22-injektion → B23 → A21 → C10 (`OnboardingView` der binder trinene) → Settings. Se **Fase 0** i planen.

---

## A. 20 FORBEDRINGER (hærdning af det eksisterende)

1. **Line-replace / diff-edits for stærke modeller** — pt. altid whole-file writes (dyrt + langsomt på store filer). `ModelConfig.supportsLineReplace` findes allerede. *Sådan:* ny `.inLineReplaceBody`-state i `StreamingArtifactParser`, `ForgeAction.lineReplace(path,search,replace)`, diff-apply i `ActionExecutor`, og en prompt-gren i `SystemPrompt`/`MessageBuilder` valgt på `config.supportsLineReplace`. **L · P0**

2. **Smart context-styring** — `AppModel.buildContext` sender hele `App.tsx` + fil-listen hver tur; sprænger `num_ctx` på store projekter (den stille trunkering vi allerede frygter). *Sådan:* token-budgettér; medtag kun filer modellen rørte sidst + dem den eksplicit anmoder om via et nyt `read-file`-værktøj; komprimér fil-mappet. **L · P0** — ✅ **A2b (read-file) bygget:** modellen kan midt i en build bede om en fils indhold via `<forgeAction type="read-file" filePath="…">`; `StreamingArtifactParser` → `.readRequest`, `AgentLoop` kører en læse-runde (henter filerne, fodrer dem tilbage, maks 3 runder, tæller ikke som repair), `Dependencies.readFile` leverer dem fra workspace. Parser-test dækker det.

3. **Afbryd/stop en kørende generering** — ingen stop-knap i dag; en lang/forkert tur kan ikke annulleres. *Sådan:* `AgentLoop.run` returnerer allerede en `AsyncStream` med en `Task` — eksponér `cancel()`; composer-knappen viser "stop" mens `isBusy`, kalder cancel → afslut stream + behold delvist arbejde. **S · P0**

4. **Keychain-baseret nøgleopbevaring + Settings-UI** — cloud-nøgle læses fra `FORGE_CLOUD_API_KEY` env-var (skrøbeligt, ikke brugervenligt). *Sådan:* lille `KeychainStore`-wrapper; et Settings-vindue (⌘,) til nøgler pr. provider + node-sti-override (`NodeResolver.overrideDefaultsKey` findes). **M · P0**

5. **Bedre fejl-klassificering** — `ErrorClassifier` er streng-matchning og fanger støj (HMR-reconnect mm.). *Sådan:* parse Vite/tsc/esbuild struktureret (fil:linje:kol + kode), dedupér på fil+linje, whitelist ægte fejlmønstre, filtrér info-logs fra. Forbedrer self-correction-konvergens direkte. **M · P0**

6. **Hærdet streaming-parser (fuzz + edge cases)** — robust mod delte tags i dag, men ikke fuzz-testet for nested/ufuldstændige artefakter, kæmpe filer, `<`-tunge filer. *Sådan:* property-based/fuzz-tests i `StreamingArtifactParserTests`; eksplicit håndtering af uafsluttet artefakt ved stream-slut. **M · P1**

7. **Token- og omkostnings-tælling** — ✅ *bygget.* OpenAI-compat-provideren sender `stream_options.include_usage` og parser usage-chunken; `ChatStreamEvent.done` → `AgentEvent.usage` → `AppModel` akkumulerer `turnTokens` (pr. tur) + `projectTokens` (pr. projekt), vist i en pille i chat-headeren (denne tur + total på hover). Ollama rapporterede allerede; cloud-providere parser endnu ikke usage. **S · P1**

8. **Cache node_modules på tværs af projekter** — hvert nyt projekt kører fuld `npm install`. *Sådan:* skift til `pnpm` med delt store (`PackageManager.pnpm` findes), eller en forvarmet template med node_modules pre-installeret + `npm ci`. Markant hurtigere første-build. **M · P1**

9. **Persistér dev-server-logs + JS-fejl pr. projekt** — pt. in-memory, tabt ved projektskift. *Sådan:* skriv `serverLog`/`jsErrors` til `.forge/logs.json` (parallelt med `chat.json` i `ProjectStore`); genindlæs ved switch. **S · P1**

10. **Smartere WebView-reload** — bevar scroll-position ved HMR; detektér white-screen/crash og auto-recover. *Sådan:* JS-broen rapporterer scrollY før reload + gendanner; en heartbeat der opdager blank `#root` og trigger reload/fix. **M · P1**

11. **Self-correction der ser den fejlende fil** — repair-turen får kun fejlteksten, ikke filens nuværende indhold. *Sådan:* `MessageBuilder.errorTurn` inkluderer den/de fil(er) fejlen peger på (fra `ErrorReport.Item`-fil-sti). Færre forkerte fixes. **M · P1**

12. **Robust orphan-håndtering for ALLE projekter** — ✅ *bygget.* `ProcessSupervisor.reclaimAllOrphans(under:)` laver en global sweep ved opstart: matcher processer hvis kommandolinje refererer Forge-projektmappen OG ligner en dev-server (`vite`/`forge-run.sh`), SIGTERM→SIGKILL. Editorer med et projekt åbent og fremmede vite-processer røres ikke. Wiret i `AppModel.init` off-main før resume-`start()`. Supplerer den per-projekt pidfile-reclaim + `forge-run.sh`-watchdog. **S · P1**

13. **NodeResolver-caching + tydelig "mangler Node"-UI** — login-shell-probe (~100-300ms) køres ved hver `start`. *Sådan:* cache resolved sti i UserDefaults m/ invalidation; hvis Node mangler, vis en handlingsrettet besked (de søgte stier findes allerede i `DevServerError.nodeRuntimeNotFound`). **S · P1**

14. **Throttle/batch UI-opdateringer under streaming** — token-for-token `appendAssistant` + log-append kan jank'e main-thread ved hurtige streams. *Sådan:* coalesce token-appends pr. frame (CADisplayLink-agtig throttle) og log-linjer i batches. **M · P2**

15. **Tilgængelighed (a11y)** — ◑ *delvist bygget.* `.accessibilityLabel` (dansk) på ikon-knapper i composer, preview-toolbar (+ `.isSelected` på aktiv bredde) og chat-header. *Udestår:* Dynamic Type og fuld tastatur-navigation i fil-træ/lister. **M · P2**

16. **App-lags-tests** — kun `ForgeKit` er testet; `AppModel`-logik (auto-navn, projekt-skift, visual-edit-prompt) er uafprøvet. *Sådan:* udtræk ren logik (slug, projectName, prompt-bygning) til testbare funktioner; ViewInspector/snapshot for nøgle-views. **M · P2**

17. **Migrér det gamle single-projekt** — `~/Library/.../Forge/project` er nu forældreløst efter multi-projekt. *Sådan:* engangs-migration ved opstart der importerer det som et `Project` hvis det findes; ellers ryd op. **S · P2**

18. **Bekræft-dialog før destruktive handlinger** — ✅ *bygget.* "Slet projekt" beder nu om bekræftelse via `.confirmationDialog` (navngiver projektet + advarer om at kode/chat/historik slettes permanent). **S · P1**

19. **Genbrug af WebView-instans + hurtigere kold start** — preview-WebView genmonteres ved visse skift. *Sådan:* hold én pulje af WKWebView pr. projekt; forvarm `WKProcessPool`; mål og reducér tid-til-første-render. **M · P2**

20. **Strukturér prompt + few-shot eksempler pr. model-evne** — `SystemPrompt` er statisk; lokale 14B-modeller fejler oftere på format. *Sådan:* `MessageBuilder` injicerer 1–2 eksakte few-shot-eksempler for svage modeller (whole-file) og et kortere format for stærke (line-replace), styret af `ModelConfig`. Hæver first-pass success-rate. **M · P1**

21. **Konfigurerbar projekt-placering** — `ProjectStore.root` er hardcoded til App Support. *Sådan:* læs `projectsRoot` fra `PreferencesStore` (sat i onboarding/settings); default uændret; tilbyd flyt/migrér ved ændring. Kræves af onboarding-trin 2. **S · P1**

22. **Central `PreferencesStore` + Settings-vindue** — fælles config-lag (navn, placering, default-model, GitHub-owner, Vercel-scope, memory, AI_RULES-skabelon) i `preferences.json`; nøgler i Keychain. Onboarding skriver det, Settings (⌘,) redigerer det. *Sådan:* `Preferences: Codable` + `PreferencesStore`; `AppModel` læser ved init. **Fundamentet for hele §0 + A4.** **M · P0**

---

## B. 20 NYE FEATURES (net-nye evner)

1. **Checkpoints / fortryd pr. tur** — snapshot projektet før hver agent-tur; ét-klik revert til enhver tidligere tilstand (Bolt/Lovable-kerne). *Sådan:* git-commit pr. tur i projektets egen repo (genbrug deploy-git-opsætningen) ELLER kopiér `src/` til `.forge/checkpoints/<turn>/`; en tidslinje i chatten med "Gendan". **L · P0**

2. **Git-diff pr. tur i chatten** — vis hvad hver tur ændrede (tilføjet/fjernet) inline som en mini-PR. *Sådan:* git-diff mellem checkpoints (fra B1); render som farvet diff i `MessageView`. **M · P1**

3. **Supabase / backend-integration** — tilføj DB + auth til genererede apps (Lovables killer-feature). *Sådan:* en "Add backend"-handling der scaffolder Supabase-client + env, og udvider `SystemPrompt` med Supabase-mønstre; secrets i Keychain (A4). **XL · P1**

4. **Billede/screenshot-input → UI** — ✅ *bygget.* Drop et mockup/screenshot (eller vedhæft via 📎), modellen bygger matchende UI. *Sådan:* `ChatMessage.imageDataURLs` + multimodal `content`-array i `OpenAICompatProvider` (OpenAI `image_url`-parts); `MessageBuilder`/`AgentLoop` bærer billedet ind i første user-besked; `Composer` får 📎-knap + drag-and-drop drop-zone + thumbnail-strip; `AppModel` nedskalerer til JPEG-data-URL (≤1568px). Kræver en vision-model. Verificeret med `google/gemma-4-26b` (LM Studio): et login-mockup → næsten pixel-præcis match (eksakte hex-farver, felter, knap, links). **Udvidet:** indsæt et **link** → Forge tager et offscreen-screenshot af siden (`DesignCapture`, en skjult WKWebView der scroller for at trigge entrance-animationer) og vedhæfter det som design-reference; `submit()` tilføjer eksplicit “recreate this design”-framing når et billede er vedhæftet (“kopiér dette design”). Verificeret med stripe.com + vercel.com. **L · P1**

5. **shadcn/ui-integration** — lad modellen bruge shadcn-komponenter (kvalitetsløft på genereret UI). *Sådan:* baked-in template m/ shadcn forudkonfigureret; `add-dependency`/`shell`-handling kører `npx shadcn add`; prompt kender komponentsættet. **M · P1**

6. **Template-galleri** — ✅ *bygget.* Seks startpunkter på startskærmen (landing, dashboard, todo, portfolio, blog, pomodoro), hver med en detaljeret dansk brief så første build lander et imponerende sted. *Sådan:* `StarterTemplate` + `StarterTemplates.all`; `AppModel.startFromTemplate()` seeder briefen og submitter i Build-mode; et 3×2 kort-grid under composeren (ikon/titel/undertekst, hover-highlight). **M · P1**

7. **Multi-framework** — Next.js / Svelte / Vue ud over React+Vite (differentiator; Lovable er React-only). *Sådan:* `ProjectTemplate` + `DevServerManager` parametriseres på framework (dev-kommando, ready-mønster i `ViteReadyDetector` generaliseres). **XL · P2**

8. **Indbygget terminal** — kør vilkårlige kommandoer i projektet. *Sådan:* `DevServerManager.runShellCommand` findes; tilføj en terminal-pane (PTY via `Process` + en terminal-emulator-view, eller simpel kommando/output-log). **L · P2**

9. **npm-pakke-søgning + tilføj-UI** — søg + tilføj deps uden modellen. *Sådan:* npm registry-søgning; `ActionExecutor`/`runShellCommand` kører install; opdatér fil-træ. **S · P2**

10. **Chat-med-kodebasen (RAG)** — stil spørgsmål om projektets kode. *Sådan:* embeddings over `src/**` (lokal embed-model via Ollama/LM Studio — den vi netop filtrerer fra i discovery), sqlite-vec; et "spørg"-tilstand i chatten der ikke redigerer. **L · P2**

11. **Pluggbare agent-backends** — wrap Claude Agent SDK / Aider / Cline bag et `ForgeEngine`-protokol (fra research-doc'et). *Sådan:* abstrahér `AgentLoop` til en protokol; default = vores loop; valgfri adaptere kalder eksterne CLI/SDK. **L · P2**

12. **Auto-fix uden prompt** — når preview fejler, tilbyd/auto-anvend et fix proaktivt. *Sådan:* `ErrorCollector` (A5) trigger en self-correction-tur automatisk når `jsErrors`/build-fejl opstår uden for en aktiv tur, bag en toggle. **M · P1**

13. **Projekt-eksport** — zip / "åbn i VS Code" / "åbn i Finder". *Sådan:* `NSWorkspace.open` på projektmappen; zip via `Process`; menupunkter i `ProjectMenu`. **S · P1**

14. **Prompt-bibliotek + prompt-forbedring** — gem prompts; udvid en kort prompt til en detaljeret spec før build. *Sådan:* en "enhance"-knap kører en hurtig model-tur der ekspanderer prompten; gemte prompts i UserDefaults. **M · P2** — ✅ **Prompt-forbedring bygget:** ✨-knap i composeren (`AppModel.enhancePrompt` + `SystemPrompt.enhance`) udvider et kort udkast til et struktureret build-brief (resumé, skærme, interaktioner, data, stil) via plan-modellen og erstatter udkastet. `<think>`-reasoning strippes. (Prompt-bibliotek/gem mangler stadig.)

15. **Stemme-input** — diktér prompts (du har Saga/CanaryKit). *Sådan:* genbrug CanaryKit-CoreML (lokal dansk ASR) → tekst i composer; push-to-talk-knap. **M · P2**

16. **Deploy-historik + rollback** — vis tidligere Vercel-deploys + rul tilbage. *Sådan:* `vercel ls`/`vercel rollback` via `runShellCommand`; udvid `DeployPanel` med en liste. **M · P2**

17. **Miljøvariabler-editor** — `.env` for genererede apps (til API-nøgler i apps). *Sådan:* en editor i kode-visningen for `.env`; injicér i dev-server-env + Vercel-env (`vercel env`). **M · P2**

18. **MCP-server-eksponering** — eksponér filsystem/terminal/preview som MCP-værktøjer, så eksterne agenter (Claude Code, Cline) kan styre Forge. *Sådan:* en lille MCP-server (stdio) oven på `ProjectWorkspace` + `DevServerManager`. **L · P2**

19. **iOS companion** — byg på Mac/DGX, vis preview i WKWebView på iPad/iPhone over LAN/Tailscale. *Sådan:* en Forge-daemon (genbrug ForgeKit) med et lille HTTP/WS-API; en SwiftUI iOS-app der fjernstyrer + viser host'ens dev-server-URL. **XL · P2**

20. **Delbare projekter / snapshots** — eksportér et projekt (kode + chat) til en fil andre kan importere. *Sådan:* pak `ProjectStore`-mappen + `chat.json` til en `.forge`-bundle; import genskaber projektet. **M · P2**

21. **Global memory (bruger-steering)** — en vedvarende bruger-memory (præferencer/kontekst) injiceret i ALLE projekters system-prompt — som dit eget `~/.claude` memory-system. *Sådan:* `Preferences.memory`-tekst (sat i onboarding-trin 7); `MessageBuilder` tilføjer "User preferences: …" til system-beskeden; redigerbar i Settings. **M · P1**

22. **Per-projekt `AI_RULES.md` / `CLAUDE.md`** — Dyad-stil styringsfil i projekt-roden, committet/deployet med projektet, injiceret i dets system-prompt. *Sådan:* onboarding-trin 8 sætter en default-skabelon; `TemplateInstaller` skriver `AI_RULES.md` ved nyt projekt; `MessageBuilder` indlæser den pr. projekt. To-lags styring sammen med B21 (global) → projekt-specifik. **M · P1**

23. **Konto-valg (GitHub + Vercel) i setup/settings** — vælg GitHub owner/org + Vercel team-scope; brugt af deploy. *Sådan:* `gh api user` + `/user/orgs`, `vercel teams ls`; gemt i `Preferences`; `AppModel.runDeploy` bruger dem (`gh repo create <owner>/<repo>`, `vercel --scope <scope>`). **M · P1**

24. **Åbn koden i ekstern editor (VS Code / Xcode)** — åbn det genererede projekt direkte i den *rette* editor, valgt efter hvad man bygger: **VS Code** til web-projekter (Vite/React i dag), **Xcode** når et projekt er et native/Swift-mål (fremtid, jf. B7-parametrisering). *Sådan:* en "Åbn i…"-handling i `ProjectMenu` + preview-toolbar; detektér type (web = `package.json`/`vite.config` → VS Code; `*.xcodeproj`/`Package.swift` → Xcode) og kald `NSWorkspace.shared.open(dir)` med `open -a "Visual Studio Code"` / `open -a Xcode`; fald tilbage til Finder hvis editoren ikke er installeret. Live ekstern redigering virker allerede med dev-serverens HMR. Udvider B13's "åbn i VS Code". **S · P1**

25. **Multi-model roller + dansk copy-pass (agentisk)** — ✅ *bygget.* Tildel forskellige lokale modeller til **roller**: plan-model (fx nemotron, god til at arkitektere), build-model (fx qwen3.6, præcis bygger) og dansk copy-model (fx munin-qwen3.5-9b). Modellerne "bruger hinanden": build-modellen bygger, og en **copy-pass** lader copy-modellen omskrive al brugervendt tekst til naturligt dansk *uden* at røre kode/struktur/classNames. *Sådan:* `Preferences.{plan,build,copy}ModelID` + `autoCopyPass`; `AppModel.modelFor(role:)` (falder tilbage til den valgte model) + `runCopyPass()` der genbruger hele build-pipelinen (checkpoint → parser → executor → HMR → self-correction); `SystemPrompt.copyPass` med stærke "kun synlig tekst"-regler; rolle-pickers i Settings + "Dansk copy"-knap i chatten. Auto-kør efter clean build når en copy-model er sat. **M · P1**

26. **Learning mode (begynder-guide)** — ✅ *bygget.* En til/fra-knap (onboarding-trin 0 + Settings) der guider en helt ny bruger gennem vibecoding. Når den er slået til: **forklarings-kort** dukker op ved milepæle (første build kører → `preview`/`dev server`/`hot reload`; auto-fix af fejl → `error`/`self-correction`; kode-visning → `source code`/`component`; deploy → `commit`/`push`/`repository`/`GitHub`/`Vercel`), vist kun én gang hver. En altid-tilgængelig **ordbog** (book-ikon) forklarer alle fagudtryk (dansk forklaring, engelsk fagord). AI'en får en **nybegynder-tone** (forklarer hvad den gør, definerer fagord i parentes første gang). *Sådan:* `Preferences.learningMode` + `learnedLessons` (vist-én-gang); `Lessons`-katalog (dansk m/ engelske termer); `LessonCard`/`GlossaryView`; `AppModel.presentLessonIfNew(_:)` kaldt fra `submit`/`.clean`/`.repairing`/`enterCodeMode`/`deploy`; tutor-direktiv tilføjet i `composedSystemPrompt` når learningMode. **M · P1**

27. **Startskærm (launch screen) + klon fra Git** — ✅ *bygget.* Forge åbner nu på en rigtig startskærm (à la Cursor/Xcode/VS Code) i stedet for et bart promptfelt: en **sidebar** (Nyt projekt, Klon fra Git, Start tutorial, Prøv et eksempel, Seneste projekter, modelvælger) + et **prompt-først** hovedfelt med en personlig hilsen "Hvad vil du bygge, P?". Brugeren spørges **én gang i en popup** hvad de vil kaldes (`preferredName`), redigerbart i Settings. Sidebaren falder væk når en build starter (ContentView skifter til chat+preview). **Klon fra Git** er ny funktionalitet: `git clone` til et nyt projekt, og hvis det er et Node/Vite-projekt køres `npm install` + dev-server startes. *Sådan:* `StartScreen.swift` (afløser EmptyStateView) + `NamePromptView`/`CloneDialogView`; `Preferences.{preferredName,askedPreferredName}`; `AppModel.{startGreeting,setPreferredName,startTutorial,tryExample,cloneFromGit}`. **L · P1**

---

## C. 20 DESIGN-FORSLAG (UI/UX/visuelt)

1. **VS Code-agtig kode-editor** — syntax highlight, linjenumre, minimap, aktiv-linje-marker. *Sådan:* CodeMirror 6 i WebView eller Tree-sitter→`NSAttributedString` i `CodeTextView`; matcher Forges sort/hvide tema. **M · P1**

2. **Live "fil-skrives"-animation** — vis filen blive "tastet" i editoren mens modellen streamer (Bolt/Lovable-signatur). *Sådan:* `ParserEvent.fileChunk` findes allerede — rut den til editoren med en cursor-typing-effekt + auto-scroll. **M · P1**

3. **Diff-visning i chatten** — pr. tur: farvet +/- diff som en mini-PR (kobler til B2). *Sådan:* render diff i `MessageView` med grøn/rød baggrund + fil-headers. **M · P1**

4. **Floating selektions-toolbar (visuel redigering)** — i stedet for kun chat: en lille svævende bjælke på det valgte element med inline tekst-edit + hurtige stil-kontroller (farve/størrelse/spacing). *Sådan:* udvid JS-broen til at vise en overlay-toolbar; simple ændringer (tekst/className) anvendes direkte uden model-tur, komplekse routes til agenten. **L · P1**

5. **Animeret empty→split-koreografi** — preview-ruden glider ind fra højre frem for crossfade; en poleret "første build"-sekvens. *Sådan:* `matchedGeometryEffect`/asymmetriske transitions i `ContentView`; trin-for-trin reveal. **S · P1**

6. **Browser-agtig preview-chrome** — en ramme med rigtig adresselinje + enheds-bezels i mobil/tablet-tilstand. *Sådan:* tegn en device-frame omkring WebView pr. `PreviewWidth`; adresselinjen bliver redigerbar (naviger i preview'et). **M · P2**

7. **Rige chat-beskeder** — render planen som en live afkrydsnings-checklist; sammenklappelige "tænke"-sektioner; kodeblokke med kopiér-knap. *Sådan:* parse modellens nummererede plan til en checklist-komponent; `MessageView` får disclosure-grupper. **M · P1**

8. **Rigere status-tidslinje** — i stedet for spinner+tekst: en tidslinje (skriver→installerer→starter→tjekker→klar) med timing pr. trin. *Sådan:* `BuildingView`/`StatusRow` udvides; `AgentState` mapper til trin med varighed. **S · P1**

9. **Kommando-palette (⌘K)** — hurtige handlinger: nyt projekt, skift model, deploy, åbn fil, toggle code/preview. *Sådan:* en overlay-søgeliste; handlinger kalder eksisterende `AppModel`-metoder. **M · P1**

10. **Onboarding-wizard (first-run)** — fuld multi-step setup ved første launch (se **§0**): navn, placering, model, cloud-nøgle, GitHub, Vercel, global memory, default `AI_RULES.md` — med spring-over hvor relevant. *Sådan:* en `OnboardingView` kort-sekvens der skriver `PreferencesStore` (A22) + Keychain (A4); vises når ingen `Preferences` findes; setup-tjek pinger `ModelDiscovery`/`gh`/`vercel`. **L · P0**

11. **Projekt-dashboard m/ thumbnails** — ◑ *delvist bygget.* Efter et build snapshottes preview'et offscreen (via `DesignCapture`) til `.forge/thumb.png`, og "SENESTE"-listen på startskærmen viser miniaturen pr. projekt (folder-ikon indtil første build). *Udestår:* et fuldt dashboard-grid med sidst-redigeret + deploy-status. **L · P2**

12. **Formaliseret design-system + dark mode** — ✅ *bygget (dark mode-delen).* Forge er redesignet i “Midnat” (mørk pro) som standard med en lys variant bag en toggle i Settings. *Sådan:* `Theme.dyn(light:dark:)` via `NSColor(name:dynamicProvider:)` resolver pr. effektiv appearance; `Preferences.appearance` styrer `AppModel.colorScheme` → `.preferredColorScheme` på hvert vindue/sheet; `CodePane`/editor bruger dynamiske `NSColor`. Skifter øjeblikkeligt uden genstart. Verificeret i begge temaer på tværs af startskærm, chat, galleri, dialoger. *(Token-skala/elevation-formalisering udestår stadig.)* **M · P1**

13. **Venlig fejl-præsentation** — ikke rå Vite-overlay, men et pænt fejl-kort med "Fix det"-knap der fodrer self-correction. *Sådan:* JS-broen fanger overlay-fejl; vis et native kort i `PreviewPane` m/ knap → trigger repair-tur. **M · P1**

14. **Toasts / notifikationer** — for async events (deploy færdig, build fejlede) frem for kun inline. *Sådan:* et let toast-system (overlay øverst); send fra `AppModel` ved nøgle-events. **S · P2**

15. **Rigere empty-state** — seneste-projekter-grid, eksempel-galleri m/ thumbnails, forslag pr. kategori. *Sådan:* udvid `EmptyStateView` med projekt-genveje (fra `ProjectStore`) + kategoriserede prompt-chips. **S · P1**

16. **Tema-vælger for genererede apps** — ✅ *bygget.* En "Skift stil"-pensel-menu i preview-toolbaren med fem presets (Midnat, Pastel, Brutalist, Jordfarver, Mono); valg fyrer `AppModel.applyStyle` — en build-tur der kun ændrer farver/typografi/spacing, ikke struktur/logik. **M · P2**

17. **Micro-interactions & motion-sprog** — knap-tryk-states, besked-ind-animationer, skeleton-loaders, blød scroll. *Sådan:* en fælles motion-konvention i `Theme` (varigheder/curves); anvend konsekvent. **M · P2**

18. **Resizable + persistente paneler** — husk split-størrelse + sammenklappelig chat pr. projekt. *Sådan:* gem `HSplitView`-positioner i UserDefaults pr. projekt; en collapse-knap. **S · P2**

19. **App-ikon + brand-identitet** — rigtigt Forge-app-ikon, menubar-tilstedeværelse, poleret vindues-chrome (unified toolbar). *Sådan:* design et sort/hvidt ambolt/"forge"-ikon (asset catalog); `.windowToolbarStyle(.unified)`. **S · P1**

20. **Tastatur-genveje overalt + cheat sheet** — ⌘N nyt projekt, ⌘↵ send, ⌘B byg, ⌘1/2 preview/code, ⌘K palette. *Sådan:* `.keyboardShortcut` på handlinger + en `?`-overlay med oversigt. **S · P2**

---

## Implementeringsplan (faser)

Rækkefølgen er værdi- og afhængighedsstyret: hærd motoren først (så alt andet
bliver bedre), lever derefter de features der definerer produktet, lav så et
samlet design-løft, og afslut med "reach"-features. **Onboarding + config-laget
kommer dog først (Fase 0)** — det er det første brugeren møder, og navn/placering/
model/nøgler/memory/regler/konti læses af alt det øvrige.

### Fase 0 — Onboarding & config-fundament (P0) — NY
*Mål: et rent first-run-flow + det config-lag alt andet bygger på (se §0).*
- A22 PreferencesStore + Settings · A4 Keychain · A21 konfigurerbar placering · B23 konto-valg (GitHub/Vercel) · B21 global memory · B22 per-projekt AI_RULES.md · §0/C10 onboarding-wizard
- **Hvorfor først:** §0-wizard'en sætter præcis disse felter; B21+B22 hæver output-kvaliteten straks; A4 gør cloud brugbar. C10-wizard'en bygges til sidst i fasen, når felterne den udfylder findes. Estimat ~2 uger.

### Fase 1 — Motor-hærdning & kvalitet (P0)
*Mål: hver efterfølgende feature arver en hurtigere, billigere, mere robust kerne.*
- A3 Afbryd generering · A1 Line-replace-edits · A2 Smart context · A5 Bedre fejl-klassificering · A20 Few-shot pr. evne
- **Hvorfor:** A2+A5+A1 forbedrer direkte first-pass success og pris; A3 er grundlæggende UX. Estimat ~1,5 uge.

### Fase 2 — Produkt-definerende features (P0/P1)
*Mål: de ting der gør Forge til et rigtigt værktøj, ikke en demo.*
- B1 Checkpoints/fortryd · B2 Git-diff pr. tur · B12 Auto-fix · B5 shadcn · B6 Template-galleri · B13 Eksport
- **Afhænger af:** B2 bygger på B1; B12 bygger på A5. Estimat ~2-3 uger.

### Fase 3 — Design-løft (P1)
*Mål: hæv hele oplevelsen til "top-tier" konsekvent.*
- C1 Kode-editor (highlight) · C2 Live-fil-animation · C3 Diff-visning · C7 Rige beskeder · C8 Status-tidslinje · C9 ⌘K-palette · C12 Design-system + dark mode · C19 App-ikon · C15 Rigere empty-state · C13 Venlig fejl-præsentation
- **Hvorfor her:** flere kobler til Fase 2 (C3↔B2, C13↔A5/B12). Estimat ~2 uger.

### Fase 4 — Differentiatorer (P1)
- B3 Supabase-backend · B4 Billede→UI · C4 Floating selektions-toolbar · B14 Prompt-forbedring · C10 Onboarding
- **Hvorfor:** Supabase + billede-input er de store Lovable-paritets-træk; C4 gør visuel redigering førsteklasses. Estimat ~3 uger.

### Fase 5 — Reach & platform (P2)
- B7 Multi-framework · B11 Pluggbare agent-backends · B18 MCP-server · B19 iOS companion · B8 Terminal · B10 Chat-med-kodebase · C11 Dashboard m/ thumbnails
- **Hvorfor sidst:** stor scope, lavere paritets-værdi, eller afhænger af et modent fundament. Estimat ~4-6 uger.

### Løbende (drys ind mellem faser)
Hurtige gevinster der kan tages når som helst: A7 token-tælling · A9 log-persistens · A13 NodeResolver-cache · A17 migrering · A18 slet-bekræftelse · B9 npm-søgning · **B24 åbn i VS Code/Xcode** · C5 transition · C14 toasts · C18 paneler · C20 genveje.

### Anbefalet "gør-nu" top-5
1. **A22 + C10 onboarding & config** (first-run-flowet + fundamentet alt andet læser)
2. **B21 + B22 memory + AI_RULES** (løfter output-kvaliteten straks; en del af onboarding)
3. **A1 line-replace** (billigere/hurtigere edits)
4. **B1 checkpoints/fortryd** (sikkerhedsnet + Lovable-kerne)
5. **C1 syntax-highlighting** (kode-visningen ser pro ud)
