import SwiftUI

// MARK: - Тема

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, glass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .glass: "Liquid Glass"
        }
    }

    /// Оформление всего приложения. Ставим на NSApp, а не через preferredColorScheme: тот при возврате
    /// к «как в системе» не сбрасывает уже выставленную тему, и части окна оставались в разных темах.
    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    func apply() { NSApp.appearance = appearance }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system
    }

    /// Liquid Glass есть только начиная с macOS 26.
    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

private struct GlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Включена ли тема Liquid Glass.
    var isGlass: Bool {
        get { self[GlassKey.self] }
        set { self[GlassKey.self] = newValue }
    }
}

extension View {
    /// Стеклянная подложка в теме Liquid Glass, обычная плашка — в остальных.
    @ViewBuilder
    func glassPanel(_ on: Bool, cornerRadius: CGFloat = 18) -> some View {
        if on, #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.bar)
        }
    }

    @ViewBuilder
    func glassButton(_ on: Bool, prominent: Bool = false) -> some View {
        if on, #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

}

/// Материал боковой панели, как у системных приложений.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Фон окна. При прозрачности > 0 окно становится полупрозрачным: снизу размытие того, что под окном,
/// сверху цвет окна с непрозрачностью (1 − прозрачность). В Liquid Glass размытие светлее и тоньше.
struct WindowBackground: NSViewRepresentable {
    var transparency: Double
    var liquid: Bool

    func makeNSView(context: Context) -> BackgroundView { BackgroundView() }

    func updateNSView(_ v: BackgroundView, context: Context) {
        v.apply(transparency: transparency, liquid: liquid)
    }

    final class BackgroundView: NSView {
        private let blur = NSVisualEffectView()
        private let tint = NSView()
        private var transparency = 0.0
        private var liquid = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            addSubview(blur); addSubview(tint)
        }
        required init?(coder: NSCoder) { fatalError() }

        func apply(transparency: Double, liquid: Bool) {
            self.transparency = transparency
            self.liquid = liquid
            let on = transparency > 0.01
            blur.isHidden = !on
            tint.isHidden = !on
            // fullScreenUI — самый прозрачный системный материал, сам подстраивается под светлую и тёмную тему
            blur.material = .fullScreenUI
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(on ? (1 - transparency) * (liquid ? 0.5 : 0.9) : 0).cgColor
            styleWindow()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            styleWindow()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply(transparency: transparency, liquid: liquid)
        }

        override func layout() {
            super.layout()
            // Растягиваемся и под строку заголовка, чтобы она тоже была полупрозрачной
            if let content = window?.contentView, let frameView = content.superview {
                let r = frameView.convert(frameView.bounds, to: self)
                blur.frame = r; tint.frame = r
            }
        }

        private func styleWindow() {
            guard let w = window else { return }
            let on = transparency > 0.01
            // Окно остаётся непрозрачным: размытие «из-под окна» и так показывает рабочий стол.
            // С isOpaque = false macOS переставала рисовать кнопки окна и панель инструментов.
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            w.titlebarAppearsTransparent = on
            if on { w.styleMask.insert(.fullSizeContentView) }
            needsLayout = true
        }
    }
}

// MARK: - Доступ к диску

enum Access {
    /// Полный доступ к диску: без него macOS не даёт трогать контейнеры и данные других приложений.
    static var hasFullDiskAccess: Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            Locations.home.path + "/Library/Safari/Bookmarks.plist",
            Locations.home.path + "/Library/Containers/com.apple.stocks",
        ]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if let h = FileHandle(forReadingAtPath: p) { try? h.close(); return true }
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil { return true }
        }
        return false
    }

    static func openFullDiskAccess() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        revealSelfSoon()
    }

    static func openAppManagement() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
        revealSelfSoon()
    }

    /// macOS не добавляет приложения в эти списки по запросу — только кнопкой «+» или перетаскиванием.
    /// Поэтому рядом с настройками показываем Uproot.app в Finder: его остаётся перетащить в список.
    private static func revealSelfSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Ошибка «нет прав», а не «файл занят».
    static func isPermissionProblem(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/Containers/") || p.contains("/Library/Group Containers/") || !hasFullDiskAccess
    }
}

// MARK: - Окно настроек (⌘,)

struct SettingsView: View {
    @AppStorage("theme") private var theme: AppTheme = .system
    @AppStorage("transparency") private var transparency = 0.0

    /// В Liquid Glass окно не бывает прозрачнее меньше чем на 35% — ползунок показывает реальное значение.
    private var shownTransparency: Binding<Double> {
        Binding(get: { max(transparency, 0.35) },
                set: { transparency = $0 })
    }

    var body: some View {
        TabView {
            Form {
                Picker("Оформление", selection: $theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.title).tag(t).disabled(t == .glass && !AppTheme.glassAvailable)
                    }
                }
                .pickerStyle(.radioGroup)
                if !AppTheme.glassAvailable {
                    Text("Liquid Glass доступен на macOS 26 и новее.").font(.caption).foregroundStyle(.secondary)
                }
                if theme == .glass {
                Section {
                    LabeledContent {
                        HStack {
                            Slider(value: shownTransparency, in: 0.35...0.9) {
                                EmptyView()
                            } minimumValueLabel: {
                                Image(systemName: "square.fill").foregroundStyle(.secondary)
                            } maximumValueLabel: {
                                Image(systemName: "square.dashed").foregroundStyle(.secondary)
                            }
                            Text("\(Int(shownTransparency.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    } label: {
                        Text("Прозрачность окна")
                    }
                }
                }
            }
            .settingsPane()
            .tabItem { Label("Оформление", systemImage: "paintbrush") }

            AccessForm()
                .settingsPane()
                .tabItem { Label("Доступ", systemImage: "lock.shield") }
        }
        .onChange(of: theme) { _, t in t.apply() }
    }
}

/// Состояние разрешений и кнопки, ведущие в нужный раздел Системных настроек.
struct AccessForm: View {
    @State private var fda = Access.hasFullDiskAccess

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if fda {
                        Label("Выдан", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Добавить Uproot…") { Access.openFullDiskAccess() }
                    }
                } label: {
                    Text("Полный доступ к диску")
                    Text("Для удаления контейнеров других приложений")
                }
                LabeledContent {
                    Button("Добавить Uproot…") { Access.openAppManagement() }
                } label: {
                    Text("Управление приложениями")
                    Text("Для удаления приложений из App Store")
                }
            } footer: {
                // Подсказка и ссылка — по левому краю списка, кнопки — по правому, на одной линии с «Добавить»
                VStack(alignment: .leading, spacing: 10) {
                    Text("Перетащите Uproot.app в список и включите.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Показать Uproot.app в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.link).font(.caption)
                        Spacer()
                        Button("Проверить") { fda = Access.hasFullDiskAccess }
                        Button("Перезапустить") { relaunch() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)   // слева — по тексту строк; справа кнопки и так стоят по «Добавить»
                .padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fda = Access.hasFullDiskAccess
        }
    }
}

/// Перезапуск: сначала эта копия полностью закрывается, потом система открывает новую.
/// Раньше новая копия стартовала сразу, а старая не закрывалась — NSApp.terminate отказывал, пока открыт лист.
func relaunch() {
    UserDefaults.standard.synchronize()
    let path = Bundle.main.bundlePath
    let pid = ProcessInfo.processInfo.processIdentifier
    let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script, path]
    try? task.run()
    exit(0)
}

extension View {
    /// Вкладка настроек высотой ровно по содержимому: окно подстраивается под каждую вкладку.
    func settingsPane() -> some View {
        self.formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 480)
    }
}

// MARK: - Первый запуск

struct AccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accessIntroShown") private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Дайте Uproot доступ к диску").font(.title2.weight(.semibold))
                    Text("Без него часть следов не удалить").foregroundStyle(.secondary)
                }
            }
            // Без собственных полей формы: рамка списка встаёт на одну линию с заголовком и кнопками
            AccessForm()
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(-20)   // сгруппированная форма macOS добавляет свои поля по 20 точек
            HStack {
                Button("Позже") { shown = true; dismiss() }
                Spacer()
                Button("Готово") { shown = true; dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
