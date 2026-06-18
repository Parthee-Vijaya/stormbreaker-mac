import XCTest
@testable import StormbreakerKit

final class StormMemoryTests: XCTestCase {
    private func tmp() -> (g: URL, p: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("stormmem-\(UUID().uuidString)")
        return (base.appendingPathComponent("global.json"), base.appendingPathComponent("proj/.forge/memory.json"), base)
    }

    func testRememberPersistsAndDedups() {
        let (g, p, base) = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        var m = StormMemory(globalURL: g, projectURL: p)
        XCTAssertTrue(m.remember("Projektet bruger Supabase til auth", scope: .project))
        XCTAssertFalse(m.remember("projektet bruger supabase til auth", scope: .project), "near-dup skipped")
        XCTAssertEqual(m.active.count, 1)
        // Reloaded from disk → persisted.
        let m2 = StormMemory(globalURL: g, projectURL: p)
        XCTAssertEqual(m2.active.first?.entry.text, "Projektet bruger Supabase til auth")
    }

    func testScopesSeparate() {
        let (g, p, base) = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        var m = StormMemory(globalURL: g, projectURL: p)
        m.remember("P foretrækker dansk", kind: .preference, scope: .global)
        m.remember("Brug Tailwind v4", kind: .convention, scope: .project)
        XCTAssertEqual(Set(m.active.map { $0.scope }), [.global, .project])
    }

    func testForgetRemoves() {
        let (g, p, base) = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        var m = StormMemory(globalURL: g, projectURL: p)
        m.remember("fakta A", scope: .project); m.remember("fakta B", scope: .project)
        XCTAssertEqual(m.active.count, 2)
        XCTAssertNotNil(m.forget(0))
        XCTAssertEqual(m.active.count, 1)
    }

    func testPromptBlockRespectsBudgetAndNilWhenEmpty() {
        let (g, p, base) = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        var m = StormMemory(globalURL: g, projectURL: p)
        XCTAssertNil(m.promptBlock(), "empty → nil")
        for i in 0..<50 { m.remember("Fakta nummer \(i) med noget tekst der fylder en del plads", scope: .project) }
        let block = try! XCTUnwrap(m.promptBlock(budgetTokens: 60))
        XCTAssertLessThan(ContextBuilder.estimateTokens(block), 80, "stays within budget + small overhead")
    }

    func testIngestDedupsAndSupersedes() {
        let (g, p, base) = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        var m = StormMemory(globalURL: g, projectURL: p)
        m.remember("Projektet bruger npm", scope: .project)
        let added = m.ingest([
            (.project, .fact, "Projektet bruger npm", nil),                              // dup → skipped
            (.global, .preference, "P foretrækker korte svar", nil),                     // new
            (.project, .correction, "Projektet bruger pnpm i stedet", "Projektet bruger npm"),  // supersedes
        ])
        XCTAssertEqual(added, 2)
        let texts = m.active.map { $0.entry.text }
        XCTAssertTrue(texts.contains("Projektet bruger pnpm i stedet"))
        XCTAssertTrue(texts.contains("P foretrækker korte svar"))
        XCTAssertFalse(texts.contains("Projektet bruger npm"), "the superseded fact is no longer active")
    }
}
