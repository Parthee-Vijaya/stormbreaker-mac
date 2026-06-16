import XCTest
@testable import ForgeKit

final class SkillTests: XCTestCase {
    func testParseWithFrontmatter() {
        let md = """
        ---
        id: greeting
        name: Hilsen
        description: En simpel hilsen
        icon: hand.wave
        triggers: hi, hej
        mode: plan
        ---
        Sig pænt goddag til {input}.
        """
        let s = Skill.parse(md, id: "fallback", origin: .global)
        XCTAssertEqual(s?.id, "greeting")
        XCTAssertEqual(s?.name, "Hilsen")
        XCTAssertEqual(s?.triggers, ["hi", "hej"])
        XCTAssertEqual(s?.mode, .plan)
        XCTAssertEqual(s?.origin, .global)
        XCTAssertEqual(s?.prompt, "Sig pænt goddag til {input}.")
    }

    func testParseWithoutFrontmatterUsesFilenameID() {
        let s = Skill.parse("Byg en taskbar.", id: "taskbar", origin: .project)
        XCTAssertEqual(s?.id, "taskbar")
        XCTAssertEqual(s?.triggers, ["taskbar"])   // defaults to [id]
        XCTAssertEqual(s?.mode, .build)
        XCTAssertEqual(s?.prompt, "Byg en taskbar.")
    }

    func testParseEmptyBodyIsNil() {
        XCTAssertNil(Skill.parse("---\nid: x\nname: X\n---\n\n   ", id: "x", origin: .builtin))
    }

    func testExpandInterpolatesInput() {
        let s = Skill(id: "t", name: "t", prompt: "Byg en app om {input}.")
        XCTAssertEqual(s.expand(input: "katte"), "Byg en app om katte.")
    }

    func testExpandAppendsWhenNoPlaceholder() {
        let s = Skill(id: "t", name: "t", prompt: "Byg en app.")
        XCTAssertEqual(s.expand(input: "med dark mode"), "Byg en app.\n\nmed dark mode")
        XCTAssertEqual(s.expand(input: "   "), "Byg en app.")
    }

    func testBuiltinsIncludeTodo() {
        XCTAssertTrue(SkillStore.builtins.contains { $0.id == "todo" })
        XCTAssertTrue(SkillStore.builtins.allSatisfy { !$0.prompt.isEmpty })
    }

    func testLoadDirParsesMarkdownFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-skill-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\nname: Custom\n---\nByg noget custom."
            .write(to: dir.appendingPathComponent("custom.md"), atomically: true, encoding: .utf8)

        let loaded = SkillStore.loadDir(dir, origin: .project)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "custom")   // derived from the filename
        XCTAssertEqual(loaded.first?.name, "Custom")
        XCTAssertEqual(loaded.first?.origin, .project)
    }

    func testProjectSkillOverridesBuiltinByID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-proj-\(UUID().uuidString)")
        let skillsDir = root.appendingPathComponent(".forge/skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nid: todo\nname: Min Todo\n---\nMin egen todo-prompt."
            .write(to: skillsDir.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        let skills = SkillStore.load(projectRoot: root)
        let todo = skills.first { $0.id == "todo" }
        XCTAssertEqual(todo?.name, "Min Todo")        // project layer wins
        XCTAssertEqual(todo?.origin, .project)
    }
}
