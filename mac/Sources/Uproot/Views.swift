import SwiftUI
import Observation

@main
struct UprootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Uproot") {
            RootView().frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// macOS выдаёт разрешения (полный доступ к диску, управление приложениями) «ответственному» процессу.
    /// Если Uproot запустили из терминала или другой программы, ответственной станет она, а не Uproot.
    /// Поэтому в таком случае перезапускаемся через Launch Services: тогда Uproot отвечает сам за себя.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard getppid() != 1, !args.contains("--relaunched"), Bundle.main.bundleURL.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = Array(args.dropFirst()) + ["--relaunched"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if error == nil { DispatchQueue.main.async { exit(0) } }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppTheme.current.apply()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if AnimProbe.dir != nil {   // отладка: свернуть и развернуть меню и записать кадры
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AnimProbe.pressToggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { AnimProbe.pressToggle() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Общее состояние

@Observable
final class AppLibrary {
    var apps: [InstalledApp] = []
    var loading = false

    func load() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = Scanner.installedApps()
            await MainActor.run { self.apps = list; self.loading = false }
            for app in list {
                let size = Sizes.of(app.url)
                await MainActor.run {
                    if let i = self.apps.firstIndex(where: { $0.id == app.id }) { self.apps[i].size = size }
                }
            }
        }
    }
}

/// Досчитывает размеры у найденных объектов, не блокируя интерфейс.
@MainActor
func fillSizes(_ items: Binding<[Leftover]>) async {
    for item in items.wrappedValue where item.size < 0 {
        if Task.isCancelled { return }
        let url = item.url
        let size = await Task.detached(priority: .utility) { Sizes.of(url) }.value
        if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].size = size }
    }
}

// MARK: - Корень

enum Pane: Hashable { case apps, orphans, search }

struct RootView: View {
    @State private var pane: Pane = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pane"), i + 1 < a.count {
            return a[i + 1] == "orphans" ? .orphans : a[i + 1] == "search" ? .search : .apps
        }
        return .apps
    }()
    @State private var library = AppLibrary()
    @AppStorage("theme") private var theme: AppTheme = .system
    @AppStorage("transparency") private var transparency = 0.0
    @AppStorage("accessIntroShown") private var accessIntroShown = false
    // @State, а не @AppStorage: изменение через UserDefaults теряет withAnimation, и меню исчезало рывком
    @State private var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
    @State private var showAccess = false
    static let sidebarWidth: CGFloat = 220

    private var liquid: Bool { theme == .glass && AppTheme.glassAvailable }
    /// Итоговая прозрачность: в Liquid Glass окно всегда хоть немного прозрачное.
    /// Прозрачность есть только в Liquid Glass (от 35%); остальные темы — обычное непрозрачное окно.
    private var effectiveTransparency: Double { liquid ? min(max(transparency, 0.35), 0.9) : 0 }
    private var translucent: Bool { effectiveTransparency > 0.01 }

    var body: some View {
        // Своя раскладка вместо NavigationSplitView: системная анимация колонок в конце появления меню
        // разом сжимала контент (скачок ~100 точек), и обойти это внутри неё нельзя.
        // Здесь ширину меню ведёт одна анимация SwiftUI, контент сужается на каждом кадре.
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(width: sidebarVisible ? Self.sidebarWidth : 0, alignment: .trailing)
                .clipped()
            Divider().opacity(sidebarVisible ? 1 : 0)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Label("Боковое меню", systemImage: "sidebar.leading")
                }
                .help("Показать или скрыть боковое меню (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
        .background { WindowBackground(transparency: effectiveTransparency, liquid: liquid) }
        .modifier(HideToolbarBackground(on: translucent))
        .environment(\.isGlass, translucent)
        .onChange(of: theme) { _, t in t.apply() }
        .sheet(isPresented: $showAccess) { AccessSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .uprootToggleSidebar)) { _ in toggleSidebar() }
        .onAppear {
            if library.apps.isEmpty { library.load() }
            if !accessIntroShown && !Access.hasFullDiskAccess { showAccess = true }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) {
            Section("Удаление") {
                Label("Приложения", systemImage: "square.grid.2x2").tag(Pane.apps)
                Label("Остатки удалённых", systemImage: "leaf").tag(Pane.orphans)
            }
            Section("Поиск") {
                Label("Файлы и папки", systemImage: "magnifyingglass").tag(Pane.search)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background { if !translucent { SidebarMaterial().ignoresSafeArea() } }
        .safeAreaInset(edge: .bottom) {
            if !Access.hasFullDiskAccess {
                Button { showAccess = true } label: {
                    Label("Нет доступа к диску", systemImage: "exclamationmark.lock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .glassButton(liquid)
                .padding(10)
                .help("Без полного доступа к диску macOS не даст удалить контейнеры других приложений")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .apps: AppsView(library: library)
        case .orphans: OrphansView(library: library)
        case .search: SearchView()
        }
    }

    func toggleSidebar() {
        AnimProbe.record()
        withAnimation(.smooth(duration: 0.3)) { sidebarVisible.toggle() }
        UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible")
    }
}

/// Общие размеры раскладки: один отступ от краёв для шапок, списков и нижней панели.
enum Layout {
    static let edge: CGFloat = 16   // как у системного списка: флажки и размеры строк стоят в 16 точках от краёв
}

/// Кнопка настроек — последняя в панели каждого раздела, поэтому всегда стоит у правого края.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { openSettings() } label: { Label("Настройки", systemImage: "gearshape") }
            .help("Настройки Uproot (⌘,)")
    }
}

/// При прозрачности у панели инструментов не должно быть своей подложки — иначе верх окна темнее остального.
struct HideToolbarBackground: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on, #available(macOS 15, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Системное поле поиска фиксированной ширины (у .searchable ширина меняется в конце анимации меню).
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

// MARK: - Приложения

struct AppsView: View {
    @Bindable var library: AppLibrary
    @Environment(\.isGlass) private var glass
    @State private var selection: URL?
    @State private var query = ""
    @State private var sortBySize = false

    private var shown: [InstalledApp] {
        var list = query.isEmpty ? library.apps : library.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(query)
        }
        if sortBySize { list.sort { ($0.size ?? 0) > ($1.size ?? 0) } }
        return list
    }

    var body: some View {
        // HStack вместо HSplitView: NSSplitView внутри NavigationSplitView дёргается при скрытии бокового меню
        HStack(spacing: 0) {
            List(shown, selection: $selection) { app in
                AppRow(app: app).tag(app.url)
            }
            .listStyle(.inset)
            .scrollContentBackground(glass ? .hidden : .automatic)
            .overlay { if library.loading { ProgressView() } }
            .frame(width: 310)

            Divider()

            Group {
                if let app = library.apps.first(where: { $0.url == selection }) {
                    AppDetailView(app: app) { library.load() }.id(app.url)
                } else {
                    ContentUnavailableView {
                        Label("Выберите приложение", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Uproot покажет все его файлы в системе.")
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Приложения")
        .navigationSubtitle(library.loading ? "Загрузка…" : "\(library.apps.count) установлено")
        // Элементы прижаты вправо, у поиска фиксированная ширина: при сворачивании меню им некуда перескакивать
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $query, prompt: "Название или идентификатор")
                    .frame(width: 230)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Сортировка", selection: $sortBySize) {
                    Text("По имени").tag(false)
                    Text("По размеру").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Сортировка списка")
                Button { library.load() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Перечитать список приложений")
            }
            ToolbarItem(placement: .primaryAction) { SettingsButton() }
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Icons.of(app.url, size: 32))
                .resizable().interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.version.flatMap { $0.isEmpty ? nil : "Версия \($0)" } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(app.size.map(Sizes.text) ?? "…")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct AppDetailView: View {
    let app: InstalledApp
    var onRemoved: () -> Void

    @State private var items: [Leftover] = []
    @State private var scanning = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RemovalPanel(
                items: $items,
                busy: scanning,
                disabledReason: app.isProtected ? "Встроенное приложение Apple — macOS не даёт его удалить" : nil,
                prepare: { chosen in
                    guard chosen.contains(where: { $0.category == .app }) else { return nil }
                    return await Remover.quit(bundleID: app.bundleID)
                        ? nil : "\(app.name) не закрывается. Закройте его вручную и повторите."
                },
                onFinished: { r in if r.moved.contains(app.url) { onRemoved() } }
            ) {
                ContentUnavailableView("Следов не осталось", systemImage: "checkmark.seal")
            }
        }
        .task {
            let found = await Task.detached(priority: .userInitiated) { Scanner.leftovers(for: app) }.value
            items = found
            scanning = false
            await fillSizes($items)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: Icons.of(app.url, size: 64))
                .resizable().interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title2.weight(.semibold))
                if let id = app.bundleID {
                    Text(id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                .fixedSize()
        }
        .padding(.horizontal, Layout.edge)
        .padding(.vertical, 16)
    }

    private var summary: String {
        if scanning { return "Поиск следов…" }
        let total = items.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let traces = max(items.count - 1, 0)
        return "\(traces) \(plural(traces, "след", "следа", "следов")) · \(Sizes.text(total))"
    }
}

// MARK: - Остатки удалённых приложений

struct OrphansView: View {
    @Bindable var library: AppLibrary
    @State private var items: [Leftover] = []
    @State private var scanning = false
    @State private var scanned = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.title3)
                Text("Файлы приложений, которых больше нет на Mac.")
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.edge)
            .padding(.vertical, 12)
            Divider()
            RemovalPanel(items: $items, busy: scanning, busyText: "Сверяю папки с установленными приложениями…") {
                if scanned {
                    ContentUnavailableView("Остатков нет", systemImage: "leaf")
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Остатки удалённых")
        .navigationSubtitle(scanned ? "\(items.count) найдено" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await scan() } } label: { Label("Проверить снова", systemImage: "arrow.clockwise") }
                    .disabled(scanning)
            }
            ToolbarItem(placement: .primaryAction) { SettingsButton() }
        }
        .task(id: library.apps.count) { if !library.apps.isEmpty && !scanned { await scan() } }
    }

    private func scan() async {
        scanning = true
        let installed = library.apps
        items = await Task.detached(priority: .userInitiated) { Scanner.orphans(installed: installed) }.value
        scanning = false
        scanned = true
        await fillSizes($items)
    }
}

// MARK: - Поиск файлов

struct SearchView: View {
    @State private var query = ""
    // По умолчанию — домашняя папка: там «Загрузки», «Документы», «Рабочий стол», где обычно и ищут файлы
    @State private var scope: Scanner.Scope = .home
    @State private var items: [Leftover] = []
    @State private var searching = false
    @State private var searched = false
    @State private var stopped = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Часть имени: например, zoom, telegram, adobe", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(start)
                Picker("", selection: $scope) {
                    ForEach(Scanner.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                // Постоянная ширина: «Искать» и «Стоп» разной длины, и соседний список прыгал
                Button(action: searching ? stop : start) {
                    Text(searching ? "Стоп" : "Искать").frame(minWidth: 56)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!searching && query.trimmingCharacters(in: .whitespaces).count < 2)
            }
            .padding(.horizontal, Layout.edge)
            .padding(.vertical, 12)
            Divider()
            RemovalPanel(items: $items, busy: searching, busyText: "Ищу… найдено \(items.count)") {
                ContentUnavailableView {
                    Label(stopped ? "Поиск остановлен" : searched ? "Ничего не нашлось" : "Поиск по имени",
                          systemImage: stopped ? "stop.circle" : "magnifyingglass")
                }
            }
        }
        .navigationTitle("Поиск файлов")
        .toolbar { ToolbarItem(placement: .primaryAction) { SettingsButton() } }
        .onAppear { focused = true }
        .onDisappear(perform: stop)
    }

    private func start() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        stop()
        items = []; searching = true; searched = true; stopped = false
        let scope = scope
        task = Task {
            let stream = AsyncStream<[URL]> { cont in
                let worker = Task.detached(priority: .userInitiated) {
                    Scanner.search(q, scope: scope) { cont.yield($0) }
                    cont.finish()
                }
                cont.onTermination = { _ in worker.cancel() }
            }
            for await batch in stream {
                items += batch.map { Leftover(url: $0, category: Locations.classify($0), selected: false) }
            }
            searching = false
            await fillSizes($items)
        }
    }

    private func stop() {
        if searching { stopped = true }
        task?.cancel(); task = nil; searching = false
    }
}
