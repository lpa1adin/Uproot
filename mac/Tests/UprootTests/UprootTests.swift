import Testing
import Foundation
import AppKit
@testable import Uproot

// MARK: - Сопоставление имён

@Suite("Сопоставление следов с приложением")
struct MatchingTests {
    let docker = Scanner.Tokens(bundleID: "com.docker.docker", names: ["docker"])

    @Test("bundle ID внутри имени — как отдельный кусок")
    func bundleID() {
        #expect(Scanner.containsID("6n38vws5bx.ru.keepcoder.telegram", "ru.keepcoder.telegram"))
        #expect(Scanner.containsID("ru.keepcoder.telegram.telegramshare", "ru.keepcoder.telegram"))
        #expect(!Scanner.containsID("com.foo.barista", "com.foo.bar"))
        #expect(!Scanner.containsID("xcom.foo.bar", "com.foo.bar"))
    }

    @Test("Имена папок и файлов", arguments: [
        ("com.docker.docker.plist", true),
        ("Docker Desktop", true),
        ("docker-secrets-engine", true),
        ("Docker", true),
        ("Dock", false),
        ("com.apple.dock.plist", false),
        ("DockerHelperX", false),
    ])
    func names(name: String, expected: Bool) {
        #expect(Scanner.matches(name, docker) == expected)
    }

    @Test("Короткие имена не цепляют чужое по префиксу")
    func shortNames() {
        let code = Scanner.Tokens(bundleID: nil, names: ["code"])
        #expect(Scanner.matches("Code", code))
        #expect(!Scanner.matches("Code Helper", code))
        #expect(!Scanner.matches("Xcode", code))
    }

    @Test("Общие имена исполняемых файлов отбрасываются")
    func genericExecutable() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), name: "Visual Studio Code",
                               bundleName: "Code", bundleID: "com.microsoft.VSCode", executable: "Electron", version: "1.0")
        let t = Scanner.tokens(for: app)
        #expect(!t.names.contains("electron"))
        #expect(t.names.contains("visual studio code"))
        #expect(t.bundleID == "com.microsoft.vscode")
    }
}

// MARK: - Защита

@Suite("Защита системных путей")
struct GuardTests {
    let home = Locations.home

    @Test("Корни и системные папки защищены")
    func roots() {
        for p in ["/", "/System", "/Applications", "/Library", "/Users", "/usr/bin/ls", "/System/Library/CoreServices", "/bin/sh"] {
            #expect(Guard.isProtected(URL(fileURLWithPath: p)), "\(p) должен быть защищён")
        }
        for sub in ["", "Library", "Desktop", "Documents", "Downloads", "Library/Caches", "Library/Preferences", "Library/Containers"] {
            #expect(Guard.isProtected(home.appendingPathComponent(sub)), "~/\(sub) должен быть защищён")
        }
    }

    @Test("Следы приложений не защищены")
    func traces() {
        #expect(!Guard.isProtected(home.appendingPathComponent("Library/Caches/com.docker.docker")))
        #expect(!Guard.isProtected(home.appendingPathComponent("Library/Application Support/Docker Desktop")))
        #expect(!Guard.isProtected(URL(fileURLWithPath: "/usr/local/bin/sometool")))
        #expect(!Guard.isProtected(URL(fileURLWithPath: "/Applications/Docker.app")))
    }

    @Test("Настройки Apple защищены, их кэши — нет")
    func appleFiles() {
        #expect(Guard.isProtected(home.appendingPathComponent("Library/Preferences/com.apple.finder.plist")))
        #expect(!Guard.isProtected(home.appendingPathComponent("Library/Caches/com.apple.Safari")))
    }

    @Test("Защищённый объект нельзя выбрать для удаления")
    func leftoverRespectsGuard() {
        let l = Leftover(url: home.appendingPathComponent("Library"), category: .other, selected: true)
        #expect(l.isProtected)
        #expect(!l.selected)
    }
}

// MARK: - Категории, размеры, окончания

@Suite("Вспомогательная логика")
struct HelperTests {
    let home = Locations.home

    @Test("Категория по пути — по самому точному совпадению")
    func classify() {
        #expect(Locations.classify(home.appendingPathComponent("Library/Caches/x")) == .caches)
        #expect(Locations.classify(home.appendingPathComponent("Library/Preferences/ByHost/x.plist")) == .prefs)
        #expect(Locations.classify(home.appendingPathComponent("Library/Logs/DiagnosticReports/a.ips")) == .logs)
        #expect(Locations.classify(URL(fileURLWithPath: "/Applications/Foo.app")) == .app)
        #expect(Locations.classify(URL(fileURLWithPath: "/private/var/db/receipts/com.foo.bom")) == .receipts)
        #expect(Locations.classify(URL(fileURLWithPath: "/opt/thing")) == .other)
    }

    @Test("Размер папки считается, несуществующая — 0")
    func sizes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uproot-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 50_000).write(to: dir.appendingPathComponent("sub/b.bin"))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Sizes.of(dir) >= 150_000)
        #expect(Sizes.of(dir.appendingPathComponent("нет такого")) == 0)
        #expect(Sizes.text(-1) == "…")
    }

    @Test("Русские окончания", arguments: [(1, "объект"), (2, "объекта"), (4, "объекта"), (5, "объектов"),
                                             (11, "объектов"), (12, "объектов"), (21, "объект"), (22, "объекта"), (112, "объектов")])
    func plurals(n: Int, word: String) {
        #expect(plural(n, "объект", "объекта", "объектов") == word)
    }

    @Test("Темы: светлая, тёмная, системная")
    func themes() {
        #expect(AppTheme.light.appearance?.name == .aqua)
        #expect(AppTheme.dark.appearance?.name == .darkAqua)
        #expect(AppTheme.system.appearance == nil)
        #expect(AppTheme.glass.appearance == nil)
    }
}

// MARK: - Сценарии на настоящей файловой системе (только свои тестовые файлы)

@Suite("Поиск и удаление на тестовом приложении", .serialized)
struct ScenarioTests {
    let fm = FileManager.default
    let id = "local.uprootTest.app\(Int.random(in: 1000...9999))"

    /// Тестовое приложение во временной папке + его кэш и настройки в ~/Library.
    func makeFakeApp() throws -> (InstalledApp, [URL]) {
        let appURL = fm.temporaryDirectory.appendingPathComponent("UprootFake-\(UUID().uuidString)/UprootFake.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let cache = Locations.home.appendingPathComponent("Library/Caches/\(id)")
        let prefs = Locations.home.appendingPathComponent("Library/Preferences/\(id).plist")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appendingPathComponent("c"))
        try Data("x".utf8).write(to: prefs)
        let app = InstalledApp(url: appURL, name: "UprootFake", bundleName: "UprootFake", bundleID: id, executable: "UprootFake", version: "1")
        return (app, [appURL.deletingLastPathComponent(), cache, prefs])
    }

    @Test("Находит кэш и настройки приложения, и ничего чужого")
    func findsLeftovers() throws {
        let (app, cleanup) = try makeFakeApp()
        defer { cleanup.forEach { try? fm.removeItem(at: $0) } }
        let found = Scanner.leftovers(for: app)
        let paths = Set(found.map(\.url.lastPathComponent))
        #expect(found.first?.category == .app)
        #expect(paths.contains(id))
        #expect(paths.contains("\(id).plist"))
        #expect(found.count == 3, "лишнее: \(found.map(\.url.path))")
        #expect(found.allSatisfy { $0.selected })
    }

    @Test("Остаток удалённого приложения находится, а файл того же разработчика — нет")
    func orphans() throws {
        let ghost = Locations.home.appendingPathComponent("Library/Caches/com.uproottestvendor.ghost\(Int.random(in: 1000...9999))")
        try fm.createDirectory(at: ghost, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ghost) }

        let none: [InstalledApp] = []
        #expect(Scanner.orphans(installed: none).contains { $0.url.path == ghost.path })

        let sibling = InstalledApp(url: URL(fileURLWithPath: "/Applications/Other.app"), name: "Other", bundleName: nil,
                                   bundleID: "com.uproottestvendor.other", executable: nil, version: nil)
        #expect(!Scanner.orphans(installed: [sibling]).contains { $0.url.path == ghost.path })
        #expect(Scanner.orphans(installed: none).allSatisfy { !$0.selected }, "остатки не должны быть отмечены заранее")
    }

    @Test("Перенос в Корзину работает и не трогает защищённое")
    func trash() throws {
        let file = fm.temporaryDirectory.appendingPathComponent("uproot-trash-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        let r = Remover.moveToTrash([file, URL(fileURLWithPath: "/System/Library")])
        // Тестовую пустышку убираем и из Корзины, чтобы она там не копилась
        defer { r.trashed.forEach { try? fm.removeItem(at: $0) } }
        #expect(r.moved == [file])
        #expect(r.trashed.count == 1)
        #expect(!fm.fileExists(atPath: file.path))
        #expect(r.refused.map(\.path) == ["/System/Library"])
        #expect(fm.fileExists(atPath: "/System/Library"))
    }

    @Test("Поиск по имени находит папку целиком и не лезет внутрь")
    func search() throws {
        let root = Locations.home.appendingPathComponent("Library/Caches/uproot-search-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("inner-uprootneedle"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let needle = root.lastPathComponent
        var found: [URL] = []
        Scanner.search(needle, scope: .libraries) { found += $0 }
        #expect(found.map(\.path) == [root.path])
    }
}
