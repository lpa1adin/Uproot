import AppKit

enum Scanner {
    private static let fm = FileManager.default

    // MARK: Установленные приложения

    static func installedApps() -> [InstalledApp] {
        var urls: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), Locations.home.appendingPathComponent("Applications")] {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for item in items {
                if item.pathExtension == "app" { urls.append(item); continue }
                // папки вроде /Applications/Utilities или «Adobe Photoshop 2026/»
                if let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    urls += sub.filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls.map { url in
            let b = Bundle(url: url)
            let info = b?.infoDictionary ?? [:]
            return InstalledApp(
                url: url,
                name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                bundleName: info["CFBundleName"] as? String,
                bundleID: b?.bundleIdentifier,
                executable: info["CFBundleExecutable"] as? String,
                version: info["CFBundleShortVersionString"] as? String
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Следы конкретного приложения

    private static let genericNames: Set<String> = ["electron", "app", "main", "launcher", "run", "macos", "helper", "java", "python", "node", "setup", "installer", "update", "updater"]

    struct Tokens {
        let bundleID: String?
        let names: [String]
    }

    static func tokens(for app: InstalledApp) -> Tokens {
        var names = Set<String>()
        for n in [app.name, app.bundleName, app.executable].compactMap({ $0?.lowercased() }) {
            if n.count >= 3 && !genericNames.contains(n) { names.insert(n) }
        }
        return Tokens(bundleID: app.bundleID?.lowercased(), names: Array(names))
    }

    /// Найти все следы приложения. Возвращает список без размеров — их досчитывают отдельно.
    static func leftovers(for app: InstalledApp) -> [Leftover] {
        let t = tokens(for: app)
        var found: [Leftover] = [Leftover(url: app.url, category: .app, selected: true)]
        var seen: Set<String> = [app.url.path]

        for (dir, cat) in Locations.all {
            guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in children where matches(name, t) {
                let url = dir.appendingPathComponent(name)
                guard !seen.contains(url.path), url.path != app.url.path else { continue }
                // Внутри ~/Applications ищем только .app
                if cat == .app && url.pathExtension != "app" { continue }
                seen.insert(url.path)
                found.append(Leftover(url: url, category: cat, selected: true))
            }
        }
        return found.sorted { ($0.category, $0.url.lastPathComponent) < ($1.category, $1.url.lastPathComponent) }
    }

    static func matches(_ rawName: String, _ t: Tokens) -> Bool {
        let n = rawName.lowercased()
        if let id = t.bundleID, containsID(n, id) { return true }

        var base = n
        for ext in [".plist", ".savedstate", ".binarycookies", ".log", ".bom", ".app", ".ips", ".crash", ".diag"] where base.hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
        }
        for name in t.names {
            let compact = name.replacingOccurrences(of: " ", with: "")
            if base == name || base == compact { return true }
            if name.count >= 5 {
                for sep in [" ", "-", "_"] where base.hasPrefix(name + sep) || base.hasPrefix(compact + sep) {
                    return true
                }
            }
        }
        return false
    }

    /// id входит в имя как отдельный кусок: com.foo.bar совпадает с «TEAM.com.foo.bar» и «com.foo.bar.helper»,
    /// но не с «com.foo.barista».
    static func containsID(_ n: String, _ id: String) -> Bool {
        var from = n.startIndex
        while from < n.endIndex, let r = n.range(of: id, range: from..<n.endIndex) {
            let beforeOK = r.lowerBound == n.startIndex || !isWordChar(n[n.index(before: r.lowerBound)])
            let afterOK = r.upperBound == n.endIndex || !isWordChar(n[r.upperBound])
            if beforeOK && afterOK { return true }
            from = n.index(after: r.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    // MARK: Остатки уже удалённых приложений

    private static let reverseDNS = try! NSRegularExpression(pattern: "^[a-z0-9-]+\\.[a-z0-9-]+\\.[a-z0-9._-]+$", options: .caseInsensitive)

    /// Папки и файлы с именем-идентификатором (com.vendor.app), для которых в системе нет приложения.
    static func orphans(installed: [InstalledApp]) -> [Leftover] {
        let installedIDs = Set(installed.compactMap { $0.bundleID?.lowercased() })
        let places: [(String, Category)] = [
            ("Application Support", .support), ("Caches", .caches), ("Preferences", .prefs),
            ("Containers", .containers), ("Saved Application State", .state),
            ("HTTPStorages", .web), ("WebKit", .web), ("Logs", .logs), ("LaunchAgents", .launch),
        ]
        var result: [Leftover] = []
        var cache: [String: Bool] = [:]

        for (sub, cat) in places {
            let dir = Locations.home.appendingPathComponent("Library/" + sub)
            guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in children {
                var id = name.lowercased()
                for ext in [".plist", ".savedstate", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
                guard reverseDNS.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil,
                      !systemPrefixes.contains(where: { id.hasPrefix($0) }) else { continue }

                let alive: Bool
                if let c = cache[id] { alive = c } else {
                    alive = isAlive(id, installedIDs)
                    cache[id] = alive
                }
                if !alive {
                    result.append(Leftover(url: dir.appendingPathComponent(name), category: cat, selected: false))
                }
            }
        }
        return result.sorted { ($0.category, $0.url.lastPathComponent) < ($1.category, $1.url.lastPathComponent) }
    }

    /// Идентификаторы системы и инструментов, которые не являются приложениями.
    private static let systemPrefixes = ["com.apple.", "group.com.apple.", "systemgroup.", "org.cups.", "org.swift.",
                                         "sh.brew.", "com.openssh.", "org.mozilla.nss"]

    private static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    private static func isAlive(_ id: String, _ installed: Set<String>) -> Bool {
        if installed.contains(id) { return true }
        // Общие файлы разработчика (com.microsoft.office.plist) не трогаем, пока стоит хоть одно его приложение
        let v = vendor(id)
        if installed.contains(where: { vendor($0) == v }) { return true }
        // com.vendor.app.helper → принадлежит com.vendor.app
        for i in installed where id.hasPrefix(i + ".") || i.hasPrefix(id + ".") { return true }
        // приложение может лежать где угодно — спросим Launch Services
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    // MARK: Поиск по имени

    enum Scope: String, CaseIterable, Identifiable {
        case home = "Домашняя папка", libraries = "Программы и библиотеки", disk = "Весь диск"
        var id: String { rawValue }
        var roots: [URL] {
            switch self {
            case .home: [Locations.home]
            case .libraries: [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Library"),
                              Locations.home.appendingPathComponent("Library"), URL(fileURLWithPath: "/usr/local"),
                              URL(fileURLWithPath: "/opt")]
            case .disk: [URL(fileURLWithPath: "/")]
            }
        }
    }

    private static let skipDirs: Set<String> = ["/System", "/Volumes", "/dev", "/private/var/vm", "/cores", "/proc", "/Network"]

    /// Обходит папки и отдаёт совпадения пачками. Совпавшая папка целиком считается одним результатом.
    static func search(_ query: String, scope: Scope, limit: Int = 3000,
                       onBatch: @escaping ([URL]) -> Void) {
        let q = query.lowercased()
        var batch: [URL] = []
        var total = 0
        var lastFlush = Date()

        for root in scope.roots {
            let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                  options: [], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                if Task.isCancelled || total >= limit { break }
                let path = url.path
                if skipDirs.contains(path) || path.hasPrefix(Locations.home.path + "/.Trash") {
                    e?.skipDescendants(); continue
                }
                if url.lastPathComponent.lowercased().contains(q) {
                    batch.append(url); total += 1
                    e?.skipDescendants()
                }
                if !batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.15 {
                    onBatch(batch); batch.removeAll(); lastFlush = Date()
                }
            }
        }
        if !batch.isEmpty { onBatch(batch) }
    }
}
