// Fun, rotating status lines shown while the agent is thinking/coding — instead
// of a flat "Skriver kode…". Movie & famous-quote parodies, leaning on coding and
// dev culture. Pure data; pick one at random per working state and rotate on a
// timer during long turns. Kept short (~≤55 chars) to fit the status bar.
import StormbreakerKit

enum StormQuotes {
    static let working: [String] = [
        // James Bond
        "My name is JS. Node JS.",
        "I like my Python not stirred",
        "Shaken, not stirred — like my async",
        "Licence to kill -9",
        "You only compile twice",
        "The world is not enough RAM",
        "Diamonds are forever, cache is not",
        "For your eyes only: this stack trace",
        "Q is compiling your gadgets",
        "A martini, and a clean merge",
        "Goldfinger? Golden linter",
        "No time to deploy",
        // Terminator
        "I'll be back — after this build",
        "Come with me if you want to ship",
        "Hasta la vista, bug",
        "Your API key — give it to me",
        "Skynet is just a cron job, relax",
        // Star Wars
        "May the source be with you",
        "These aren't the bugs you're looking for",
        "I find your lack of tests disturbing",
        "Do. Or do not. There is no try-catch",
        "It's a trap! (infinite loop)",
        "Help me, Stack Overflow, you're my only hope",
        "The merge is strong with this one",
        "I am your father class",
        "Use the fork, Luke",
        "Now this is podracing… I mean piping",
        "Hello there — General Compiler",
        // Marvel / Avengers
        "Avengers, assemble the build",
        "I am Iron… clad typing",
        "With great power comes great refactoring",
        "I can do this all day (CI)",
        "We have a Hulk… of legacy code",
        "I am inevitable, said the merge conflict",
        "That's my secret — I'm always compiling",
        "I am Groot (and so is this variable)",
        "On your left — pushing to main",
        "Perfectly balanced git history",
        "I love you 3000 lines of code",
        "Wakanda forever, this loop is not",
        "Snap — and half the tests pass",
        "Mr. Stark, I don't feel so type-safe",
        "Dread it, run from it, the merge arrives",
        // Lord of the Rings
        "One script to rule them all",
        "You shall not push to main",
        "My precious… merge",
        "A wizard compiles precisely when he means to",
        "Even the smallest commit changes the build",
        "Not all who wander are lost — except this pointer",
        "Fly, you fools — the build is failing",
        "Po-ta-toes: boil 'em, mash 'em, ship 'em",
        // The Matrix
        "There is no spoon, only spaghetti code",
        "I know kung fu — and regex",
        "Follow the white stack trace",
        "What if I told you it builds on your machine",
        "Free your mind, and your memory leaks",
        "Red pill: prod. Blue pill: staging",
        "Dodge this null pointer",
        // Star Trek
        "Beam me up — the build is done",
        "Resistance is futile (to TypeScript)",
        "Live long and prosper, async",
        "Set phasers to refactor",
        "He's dead, Jim — the dev server",
        "Engage the dev server",
        "Make it so, number two commit",
        // Back to the Future
        "Where we're going we don't need roads, just routes",
        "Great Scott! 1.21 gigawatts of compute",
        "Your kids are gonna love this build",
        "Roads? We use route handlers",
        // Jurassic Park
        "Life finds a way around your validation",
        "Hold onto your butts — deploying",
        "Clever girl, this recursion",
        "We spared no expense on dependencies",
        // Star-tier one-liners (mixed films)
        "Houston, we have a merge conflict",
        "You're gonna need a bigger heap",
        "If you build it, it will deploy",
        "I'm gonna make him an offer he can't refactor",
        "Leave the gun, take the cannoli, commit the code",
        "It's not personal, it's just business logic",
        "I'm the king of the commit",
        "Draw me like one of your French interfaces",
        "Say 'merge' again, I dare you",
        "English, do you parse it?",
        "All work and no tests makes Jack a dull dev",
        "Heeere's JSON",
        "To infinity loop and beyond",
        "There's a snake in my bootstrap",
        "Are you not entertained by this trace?",
        "Why so serial…izable?",
        "It's what I commit that defines me",
        "Of all the repos, you cloned this one",
        "Here's looking at you, kernel",
        "Toto, we're not in localhost anymore",
        "Pay no attention to the dev behind the curtain",
        "ET phone home… server",
        "I've had it with these monkey-patching snakes",
        "Just keep building, just keep building",
        "P. Sherman, 42 Wallaby Way, localhost",
        "Did you get the memo about the PR?",
        "60% of the time, it builds every time",
        "What is this, a function for ants?",
        "Hakuna Matata — it's just a warning",
        "Stop trying to make this hack happen",
        "I will find this bug, and I will fix it",
        "Go ahead, make my day — commit",
        "Say hello to my little function",
        "You can't handle the truthy",
        "Failure to communicate with the API",
        "Greed is good — like memoization",
        "I see dead… locks",
        "I'm ready for my code review, Mr. DeMille",
        "I'm mad as hell and I won't parse this",
        "Be the ball, be the build",
        "Who you gonna call? Stack-busters",
        "I ain't afraid of no bug",
        "Say my name — it's Heisen-build",
        "I am the one who knocks… the build over",
        // The Princess Bride
        "You broke my build, prepare to debug",
        "Inconceivable! (this actually works)",
        "As you wish — git push",
        "Have fun storming the codebase",
        // Top Gun
        "I feel the need — the need for caching",
        "Talk to me, GPU",
        "Your ego is writing checks your RAM can't cash",
        // Rocky
        "Yo Adrian, I shipped it",
        "It's about how hard you can get pushed and keep merging",
        // Inception
        "We need to go deeper into the stack",
        "A merge within a merge within a merge",
        "You mustn't be afraid to dream a little bigger, darling",
        // Fight Club
        "First rule: you do not talk about the hotfix",
        "I am Jack's unhandled exception",
        // 2001: A Space Odyssey
        "I'm sorry Dave, I can't merge that",
        "Open the pull request, HAL",
        // Spider-Man
        "Great power, great responsibility… write tests",
        "Whatever a crawler can, so can I",
        "Pizza time — after the build",
        // The Dark Knight / Batman
        "I'm the dev this codebase deserves",
        "Some devs just want to watch the build burn",
        "It's not a bug, it's a feature… I'm Batman",
        // The Lion King
        "Remember who you are — the maintainer",
        "It's the circle of CI",
        // Gladiator / epics
        "What we commit in life echoes in prod",
        "Strength and honor — and 100% coverage",
        // Braveheart
        "They'll never take… our git history",
        "FREEDOM from callbacks",
        // Apollo / space
        "Houston, the code has landed",
        "That's one small commit for a dev",
        "Failure is not an option (it's a status code)",
        // Famous non-film quotes
        "I think, therefore I commit",
        "To be, or not to be — null",
        "Elementary, my dear Watson — it's a typo",
        "I came, I saw, I refactored",
        "Float like a butterfly, sting like a linter",
        "The only thing we have to fear is prod itself",
        "Knowledge is knowing it's a tomato; wisdom is /undo",
        "Be the change you wish to see in the diff",
        "An apple a day keeps the rollback away",
        "Genius is 1% inspiration, 99% debugging",
        "The pen is mightier than the keyboard? Doubt it",
        "Veni, vidi, git commit",
        // Casablanca / classics
        "We'll always have localhost",
        "Round up the usual suspects (the bugs)",
        "I'm shocked — shocked — to find bugs here",
        // The Shawshank Redemption
        "Get busy building, or get busy debugging",
        "Hope is a good thing, maybe the best CI",
        // Forrest Gump
        "Life is like a box of dependencies",
        "Run, build, run",
        "Stupid is as legacy does",
        // Jaws / nautical
        "Smile, you son of a bug",
        // Wall Street / business
        "Lunch is for wimps, I'm shipping",
        // The Wizard of Oz
        "There's no place like 127.0.0.1",
        "Follow the yellow brick route",
        // Taxi Driver
        "You parsin' to me?",
        // Snakes / Samuel L
        "Hold on to your semicolons",
        // Generic dev incantations
        "Reticulating splines…",
        "Summoning the build daemon",
        "Negotiating with the type checker",
        "Bribing the linter",
        "Untangling the spaghetti",
        "Consulting the rubber duck",
        "Feeding the hamsters",
        "Convincing the compiler",
        "Asking the senior dev (it's me)",
        "Googling the error in advance",
        "Pretending to understand async",
        "Counting the semicolons",
        "Aligning the indentation chakras",
        "Warming up the GPUs",
        "Brewing a fresh pot of tokens",
        "Rolling a saving throw vs. null",
        "Petting Schrödinger's bug",
        "Teaching the AI to indent",
        "Refilling the coffee buffer",
        "Compiling excuses",
        "Herding the closures",
        "Yak-shaving, professionally",
        "Translating from Stack Overflow",
        "Tabs vs spaces: negotiating peace",
        "Decrypting my own old code",
        "Whispering to the kernel",
        "Sharpening the regex",
        "Defragmenting my thoughts",
        "Spinning up the imagination engine",
        "Adding more cowbell to the build",
        "Politely asking the cache to behave",
        "Drawing the rest of the owl",
        "Casting fireball at the bug",
        "Knitting some closures",
        "Buffering brilliance",
        "Loading creativity… 99%",
        "Wrangling the promises",
        "Dusting off the documentation",
        "Convincing types they're compatible",
        "Rebooting the universe (npm install)",
        // Mr. Robot / hacker flair
        "Hello, friend. Let's compile",
        "Control is an illusion, like this deadline",
        // The Social Network
        "If you'd invented a good build, you'd have built a good build",
        // Dune
        "The spice must flow — like the data",
        "Fear is the mind-killer; null is the build-killer",
        "I must not fear the merge conflict",
        // Whiplash
        "Not quite my tempo… recompiling",
        "Were you rushing or were you dragging the FPS?",
        // Pirates of the Caribbean
        "Why is the rum (and the RAM) gone?",
        "This is the day you'll remember you almost shipped",
        // Anchorman
        "I'm not even mad, that's amazing code",
        "I immediately regret this dependency",
        // Zoolander
        "I'm pretty sure there's a lot more to code than being really good-looking",
        // Elf
        "The best way to spread cheer is shipping loud for all to hear",
        // Home Alone
        "This is my house, I have to defend it (from bugs)",
        // The Godfather II
        "Keep your friends close and your backups closer",
        // A Christmas Story
        "You'll shoot your foot off (with that regex)",
        // Field-tested dev truths (parody)
        "It works on my machine, officially",
        "Adding a comment that says // TODO: fix",
        "Renaming variables until it compiles",
        "Turning it off and on again",
        "Blaming the cache (correctly)",
        "Reading the docs for the first time",
        "Copying from my own GitHub",
        "Making it work, then making it pretty",
        "Pushing to a branch nobody will review",
        "Adding a semicolon, removing a semicolon",
        // More Bond/Marvel/SW to round out
        "Bond. Re-bound. (state)",
        "Shall we play a game? Global Thermonuclear Build",
        "I'm the boss, said the linter",
        "Wax on, refactor off",
        "There can be only one… source of truth",
        "Nobody puts the build in a corner",
        "You had me at 'it compiles'",
        "I'll have what the compiler's having",
        "Show me the money… err, the modules",
        "Houston, requesting permission to ship",
        "Loading… the suspense is the feature",
        "Almost there — said every progress bar",
        "Trust me, I'm a senior… ish",
        "Building castles in the stack",
        "Plot twist: it's a caching issue",
    ]

    /// Whether this state is a "working" phase that should show a fun quote (vs a
    /// literal label like HMR/errors/repair/clean/failed).
    static func isWorking(_ state: AgentState) -> Bool {
        switch state {
        case .planning, .building, .applying: return true
        default: return false
        }
    }
}
