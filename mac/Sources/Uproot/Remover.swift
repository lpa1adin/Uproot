import AppKit

/// Всё удаление — только в Корзину: любой объект можно вернуть, пока Корзина не очищена.
enum Remover {
    struct Report {
        var moved: [URL] = []
        var failed: [URL] = []
        var refused: [URL] = []
        /// Где файлы оказались в Корзине (для перемещённых обычным способом).
        var trashed: [URL] = []
    }

    static func moveToTrash(_ urls: [URL]) -> Report {
        var r = Report()
        for url in urls {
            if Guard.isProtected(url) { r.refused.append(url); continue }
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                r.moved.append(url)
                if let result { r.trashed.append(result as URL) }
            } catch {
                if FileManager.default.fileExists(atPath: url.path) { r.failed.append(url) } else { r.moved.append(url) }
            }
        }
        return r
    }

    /// Для файлов, принадлежащих системе: переносит их в Корзину пользователя через стандартный запрос пароля macOS.
    @MainActor
    static func moveToTrashAsAdmin(_ urls: [URL]) -> (Report, String?) {
        var r = Report()
        let safe = urls.filter { url in
            if Guard.isProtected(url) { r.refused.append(url); return false }
            return true
        }
        guard !safe.isEmpty else { return (r, nil) }

        let trash = Locations.home.appendingPathComponent(".Trash").path
        let commands = safe.map { url -> String in
            let dest = trash + "/" + url.lastPathComponent + " " + String(UUID().uuidString.prefix(5))
            return "/bin/mv -f " + shellQuote(url.path) + " " + shellQuote(dest)
        }
        let script = "do shell script \"" + appleScriptEscape(commands.joined(separator: "; ")) + "\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        for url in safe {
            if FileManager.default.fileExists(atPath: url.path) { r.failed.append(url) } else { r.moved.append(url) }
        }
        // -128 — пользователь нажал «Отменить» в окне пароля
        let cancelled = (error?[NSAppleScript.errorNumber] as? Int) == -128
        let message = cancelled ? nil : error?[NSAppleScript.errorMessage] as? String
        return (r, message)
    }

    /// Закрыть приложение перед удалением. Возвращает false, если оно не закрылось.
    static func quit(bundleID: String?) async -> Bool {
        guard let id = bundleID else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if running.allSatisfy(\.isTerminated) { return true }
        }
        return false
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
