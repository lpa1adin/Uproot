import AppKit

// MARK: - Данные

struct InstalledApp: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleName: String?
    let bundleID: String?
    let executable: String?
    let version: String?
    var size: Int64? = nil

    /// Приложения Apple защищены системой (SIP) и не удаляются.
    var isProtected: Bool { bundleID?.lowercased().hasPrefix("com.apple.") ?? false }
}

enum Category: Int, CaseIterable, Comparable {
    case app, support, caches, prefs, containers, launch, state, web, logs, receipts, other

    static func < (a: Category, b: Category) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .app: "Само приложение"
        case .support: "Данные приложения"
        case .caches: "Кэш"
        case .prefs: "Настройки"
        case .containers: "Контейнеры"
        case .launch: "Автозапуск и фоновые службы"
        case .state: "Сохранённое состояние окон"
        case .web: "Веб-данные и cookies"
        case .logs: "Журналы и отчёты о сбоях"
        case .receipts: "Квитанции установщика"
        case .other: "Другое"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.dashed"
        case .support: "folder"
        case .caches: "internaldrive"
        case .prefs: "slider.horizontal.3"
        case .containers: "shippingbox"
        case .launch: "bolt.horizontal"
        case .state: "macwindow"
        case .web: "globe"
        case .logs: "doc.text"
        case .receipts: "doc.plaintext"
        case .other: "questionmark.folder"
        }
    }
}

struct Leftover: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let category: Category
    var size: Int64 = -1          // -1 — ещё считается
    var selected: Bool
    var needsAdmin: Bool
    var isProtected: Bool = false

    init(url: URL, category: Category, selected: Bool) {
        self.url = url
        self.category = category
        self.isProtected = Guard.isProtected(url)
        self.selected = selected && !isProtected
        self.needsAdmin = !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Где приложения оставляют следы

enum Locations {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Папки внутри Library — и пользовательской (~/Library), и общей (/Library).
    static let library: [(String, Category)] = [
        ("Application Support", .support),
        ("Caches", .caches),
        ("Preferences", .prefs),
        ("Preferences/ByHost", .prefs),
        ("Containers", .containers),
        ("Group Containers", .containers),
        ("Application Scripts", .containers),
        ("LaunchAgents", .launch),
        ("Saved Application State", .state),
        ("HTTPStorages", .web),
        ("WebKit", .web),
        ("Cookies", .web),
        ("Logs", .logs),
        ("Logs/DiagnosticReports", .logs),
        ("Internet Plug-Ins", .other),
        ("PreferencePanes", .other),
        ("Services", .other),
        ("QuickLook", .other),
        ("Spotlight", .other),
        ("Audio/Plug-Ins/Components", .other),
    ]

    /// Только системные места.
    static let systemOnly: [(String, Category)] = [
        ("/Library/LaunchDaemons", .launch),
        ("/Library/PrivilegedHelperTools", .launch),
        ("/Library/Extensions", .other),
        ("/private/var/db/receipts", .receipts),
    ]

    static var all: [(URL, Category)] {
        var r: [(URL, Category)] = []
        for (sub, cat) in library {
            r.append((home.appendingPathComponent("Library/" + sub), cat))
            r.append((URL(fileURLWithPath: "/Library/" + sub), cat))
        }
        for (p, cat) in systemOnly { r.append((URL(fileURLWithPath: p), cat)) }
        r.append((home.appendingPathComponent("Applications"), .app))
        return r
    }

    /// Определить категорию по пути (для результатов поиска).
    static func classify(_ url: URL) -> Category {
        let p = url.path
        if p.hasSuffix(".app") { return .app }
        var best: (Int, Category) = (0, .other)
        for (dir, cat) in all where p.hasPrefix(dir.path + "/") && dir.path.count > best.0 {
            best = (dir.path.count, cat)
        }
        return best.1
    }
}

// MARK: - Защита от удаления важного

enum Guard {
    private static let roots: Set<String> = {
        var s: Set<String> = ["/", "/Applications", "/Library", "/System", "/Users", "/private", "/usr",
                              "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/Volumes", "/usr/local"]
        let h = Locations.home.path
        s.insert(h)
        for d in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
                  "Applications", ".Trash", "Library/Mobile Documents"] {
            s.insert(h + "/" + d)
        }
        for (u, _) in Locations.all { s.insert(u.path) }
        return s
    }()

    static func isProtected(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if roots.contains(p) { return true }
        for prefix in ["/System/", "/bin/", "/sbin/", "/usr/"] where p.hasPrefix(prefix) {
            if !p.hasPrefix("/usr/local/") { return true }
        }
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("com.apple.") && !p.hasPrefix(Locations.home.path + "/Library/Caches/") { return true }
        return false
    }
}

// MARK: - Размеры

enum Sizes {
    static func of(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: keys) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func text(_ bytes: Int64) -> String {
        bytes < 0 ? "…" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Иконки

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()
    static func of(_ url: URL, size: CGFloat) -> NSImage {
        let key = "\(url.path)#\(size)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }
}
