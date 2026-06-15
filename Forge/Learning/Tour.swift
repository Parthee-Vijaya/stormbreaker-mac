import SwiftUI

/// A spotlight in the guided tour points at one real UI element. Views mark
/// themselves with `.tourAnchor(.composer)` etc.; the overlay resolves the frames.
enum TourStop: String, CaseIterable, Identifiable {
    case composer, framework, templates, glossary, ready
    var id: String { rawValue }
}

/// One step of the guided tour: which element to spotlight, plus the narration
/// (Danish) and any English terms it teaches (same style as the milestone cards).
struct TourStep: Identifiable {
    let stop: TourStop
    let icon: String
    let title: String
    let body: String
    let terms: [Term]
    var id: String { stop.rawValue }
}

enum Tour {
    /// The launch-screen walkthrough. It narrates + highlights where you describe
    /// your app, choose how to build, and find help — then hands off to the
    /// milestone cards (welcome → app-running → errors → code → deploy) that
    /// already explain each step as the build comes to life.
    static let steps: [TourStep] = [
        TourStep(
            stop: .composer,
            icon: "text.cursor",
            title: "Her beskriver du din app",
            body: """
            Skriv i almindeligt sprog hvad du vil bygge — det kaldes en prompt — og tryk \
            Build. Så skriver AI'en koden for dig. Du behøver ikke kunne kode. Knappen Plan \
            ved siden af lader i stedet AI'en lægge en plan og stille spørgsmål, før den bygger.
            """,
            terms: [
                Term(term: "prompt", explanation: "den besked/instruktion du skriver til AI'en"),
                Term(term: "vibecoding", explanation: "at bygge software ved at beskrive det i almindeligt sprog"),
                Term(term: "plan mode", explanation: "lad AI'en lægge en plan og stille spørgsmål før den bygger"),
            ]),
        TourStep(
            stop: .framework,
            icon: "square.stack.3d.up",
            title: "Vælg teknologi",
            body: """
            Her vælger du hvilket framework din app bygges med. React er et sikkert \
            standardvalg — Svelte og Vue er alternativer. Er du i tvivl, så lad den stå på React.
            """,
            terms: [
                Term(term: "framework", explanation: "et fundament af færdig kode din app bygges ovenpå (React, Svelte, Vue)"),
            ]),
        TourStep(
            stop: .templates,
            icon: "square.grid.2x2",
            title: "Eller start fra en skabelon",
            body: """
            Har du ikke en idé klar? Vælg en færdig skabelon — fx Dashboard, Portfolio eller \
            Todo-app — med ét klik, så bygger Forge den for dig med det samme.
            """,
            terms: []),
        TourStep(
            stop: .glossary,
            icon: "book",
            title: "Ordbogen er altid lige her",
            body: """
            Møder du et engelsk fagudtryk undervejs, finder du en kort dansk forklaring i \
            ordbogen. Klik på bog-ikonet når som helst — jeg åbner den for dig nu, så du ved hvor den er.
            """,
            terms: []),
        TourStep(
            stop: .ready,
            icon: "sparkles",
            title: "Klar — så bygger vi!",
            body: """
            Jeg har skrevet en idé til dig i feltet. Tryk Build, så går vi i gang. Jeg følger \
            med og forklarer hvert skridt undervejs: din app der kører live, fejl der bliver \
            rettet automatisk, koden bag — og hvordan du lægger den på nettet.
            """,
            terms: []),
    ]
}

/// Collects the on-screen frame of each tour anchor, keyed by stop.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourStop: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStop: Anchor<CGRect>],
                       nextValue: () -> [TourStop: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Mark this view as the spotlight target for a tour stop.
    func tourAnchor(_ stop: TourStop) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [stop: $0] }
    }
}
