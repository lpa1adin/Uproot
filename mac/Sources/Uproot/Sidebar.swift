import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let uprootToggleSidebar = Notification.Name("uprootToggleSidebar")
}

/// Отладка: покадровый замер анимации меню. Включается переменной окружения UPROOT_ANIMLOG=<папка>.
/// На каждом кадре пишет положение (в координатах окна) списков, заголовка и элементов панели.
enum AnimProbe {
    static var dir: String? { ProcessInfo.processInfo.environment["UPROOT_ANIMLOG"] }
    private static var run = 0

    static func pressToggle() {
        NotificationCenter.default.post(name: .uprootToggleSidebar, object: nil)
    }

    static func record() {
        guard let dir, let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) else { return }
        run += 1
        let file = "\(dir)/anim-\(run).txt"
        var lines = ["t | списки: x/ширина | заголовок, поиск"]
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { t in
            let dt = CACurrentMediaTime() - start
            lines.append(String(format: "%.3f | ", dt) + snapshot(window))
            if dt > 0.6 {
                t.invalidate()
                try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Где элемент виден на экране сейчас: по дереву presentation-слоёв (с учётом анимаций предков).
    private static var rootLayer: CALayer?
    private static func onScreen(_ v: NSView) -> NSRect {
        guard let l = v.layer, let root = rootLayer else { return v.convert(v.bounds, to: nil) }
        let pl = l.presentation() ?? l
        let pr = root.presentation() ?? root
        return pl.convert(pl.bounds, to: pr)
    }

    private static func snapshot(_ window: NSWindow) -> String {
        guard let root = window.contentView?.superview else { return "" }
        rootLayer = root.layer
        var lists: [String] = [], bar: [String] = []
        func walk(_ v: NSView) {
            if v is NSScrollView, v.frame.width > 40, v.frame.height > 200 {
                let r = onScreen(v); lists.append("\(Int(r.minX))/\(Int(r.width))")
            }
            if let t = v as? NSTextField, ["Приложения", "Остатки удалённых", "Поиск файлов"].contains(t.stringValue),
               onScreen(v).minY < 60 {
                bar.append("заголовок=\(Int(onScreen(v).minX))")
            }
            if v is NSSearchField, onScreen(v).minY < 60 { bar.append("поиск=\(Int(onScreen(v).minX))") }
            v.subviews.forEach(walk)
        }
        walk(root)
        return lists.joined(separator: "  ") + " | " + bar.joined(separator: " ")
    }
}
