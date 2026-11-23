import SwiftUI

/// Список найденных объектов по группам, с флажками и нижней панелью «Переместить в Корзину».
struct RemovalPanel<Empty: View>: View {
    @Binding var items: [Leftover]
    var busy: Bool
    var busyText: String = "Ищу следы…"
    var disabledReason: String? = nil
    /// Вызывается перед удалением (например, закрыть приложение). Вернуть текст ошибки, чтобы отменить.
    var prepare: (([Leftover]) async -> String?)? = nil
    var onFinished: (Remover.Report) -> Void = { _ in }
    @ViewBuilder var empty: () -> Empty

    @Environment(\.isGlass) private var glass
    @State private var confirm = false
    @State private var working = false
    @State private var report: Remover.Report?
    @State private var finished: Remover.Report?
    @State private var errorText: String?

    private var selected: [Leftover] { items.filter { $0.selected && !$0.isProtected } }
    private var selectedSize: Int64 { selected.reduce(0) { $0 + max($1.size, 0) } }
    private var categories: [Category] { Array(Set(items.map(\.category))).sorted() }

    var body: some View {
        Group {
            if glass {
                // Liquid Glass: список уходит под плавающую стеклянную панель
                ZStack(alignment: .bottom) {
                    content.safeAreaPadding(.bottom, 64)
                    bar.glassPanel(true, cornerRadius: 20).padding(10)
                }
            } else {
                VStack(spacing: 0) {
                    content
                    Divider()
                    bar.background(.bar)
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirm, titleVisibility: .visible) {
            Button("Переместить в Корзину", role: .destructive) { Task { await remove() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(selected.count) \(plural(selected.count, "объект", "объекта", "объектов")) · \(Sizes.text(selectedSize))"
                 + (selected.contains(where: \.needsAdmin) ? "\nПонадобится пароль администратора." : ""))
        }
        .alert("Не получилось", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: { Text(errorText ?? "") }
        // Сообщаем наружу только после закрытия итога: иначе обновление списка закроет экран вместе с окном итога
        .sheet(item: $report, onDismiss: { if let r = finished { finished = nil; onFinished(r) } }) { r in ReportSheet(report: r) }
    }

    private var confirmTitle: String {
        "Переместить в Корзину?"
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty && !busy {
            empty().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    // MARK: Список

    private var list: some View {
        List {
            ForEach(categories, id: \.self) { cat in
                let idx = items.indices.filter { items[$0].category == cat }
                if glass {
                    // В Liquid Glass прилипающий заголовок группы рисуется непрозрачной полосой —
                    // делаем заголовок обычной строкой
                    groupHeader(cat, idx)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 8)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                    ForEach(idx, id: \.self) { i in LeftoverRow(item: $items[i]) }
                } else {
                    Section {
                        ForEach(idx, id: \.self) { i in LeftoverRow(item: $items[i]) }
                    } header: {
                        groupHeader(cat, idx)
                    }
                }
            }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyText).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: !glass))
        .scrollContentBackground(glass ? .hidden : .automatic)
    }

    private func groupHeader(_ cat: Category, _ idx: [Int]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cat.symbol).foregroundStyle(.secondary)
            Text(cat.title)
            Spacer()
            Text(Sizes.text(idx.reduce(0) { $0 + max(items[$1].size, 0) }))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: Нижняя панель

    private var bar: some View {
        HStack(spacing: 12) {
            let allOn = !items.isEmpty && items.allSatisfy { $0.selected || $0.isProtected }
            Button(allOn ? "Снять все" : "Выбрать все") {
                for i in items.indices where !items[i].isProtected { items[i].selected = !allOn }
            }
            .disabled(items.isEmpty)
            .buttonStyle(.bordered)

            if let reason = disabledReason {
                Label(reason, systemImage: "lock.shield").foregroundStyle(.secondary)
            } else {
                Text(selected.isEmpty ? "Ничего не выбрано"
                     : "Выбрано \(selected.count) · \(Sizes.text(selectedSize))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button(role: .destructive) { confirm = true } label: {
                Label("В Корзину", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected.isEmpty || working || disabledReason != nil)
        }
        .padding(.horizontal, glass ? 12 : Layout.edge)
        .padding(.vertical, 10)
    }

    // MARK: Удаление

    private func remove() async {
        let chosen = selected
        working = true
        defer { working = false }

        if let prepare, let err = await prepare(chosen) { errorText = err; return }

        let normal = chosen.filter { !$0.needsAdmin }.map(\.url)
        var r = await Task.detached { Remover.moveToTrash(normal) }.value

        // Контейнеры других приложений защищены TCC: без «Полного доступа к диску» пароль администратора не поможет,
        // поэтому зря его не спрашиваем — в итоге покажем кнопку выдачи доступа.
        let tccBlocked = { (u: URL) in !Access.hasFullDiskAccess && (u.path.contains("/Library/Containers/") || u.path.contains("/Library/Group Containers/")) }
        let adminURLs = (chosen.filter(\.needsAdmin).map(\.url) + r.failed).filter { !tccBlocked($0) }
        if !adminURLs.isEmpty {
            r.failed.removeAll { adminURLs.contains($0) }
            let (ar, msg) = Remover.moveToTrashAsAdmin(adminURLs)
            r.moved += ar.moved; r.failed += ar.failed; r.refused += ar.refused
            if let msg, !ar.failed.isEmpty { errorText = msg }
        }

        let gone = Set(r.moved.map(\.path))
        items.removeAll { gone.contains($0.url.path) }
        finished = r
        report = r
    }
}

extension Remover.Report: Identifiable {
    var id: String { (moved + failed + refused).map(\.path).joined() }
}

// MARK: - Строка

struct LeftoverRow: View {
    @Binding var item: Leftover

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $item.selected)
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(item.isProtected)
            Image(nsImage: Icons.of(item.url, size: 20))
                .resizable().interpolation(.high)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: Locations.home.path, with: "~"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.isProtected {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    .help("Системный или важный путь — Uproot его не трогает")
            } else if item.needsAdmin {
                Image(systemName: "lock").foregroundStyle(.secondary)
                    .help("Принадлежит системе — понадобится пароль администратора")
            }
            Text(Sizes.text(item.size))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(item.isProtected ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

// MARK: - Итог

struct ReportSheet: View {
    let report: Remover.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if complete { success } else { partial }
    }

    /// Всё удалено: компактное окно по размеру текста — значок, заголовок и две кнопки одной ширины.
    private var success: some View {
        VStack(spacing: 14) {
            AnimatedCheckmark(size: 44)
            Text(title).font(.headline)
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(Locations.home.appendingPathComponent(".Trash")) } label: {
                    Text("Открыть Корзину").frame(maxWidth: .infinity)
                }
                Button { dismiss() } label: { Text("Закрыть").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 340)
    }

    /// Удалено не всё: нужен список путей, поэтому окно шире и с выравниванием по левому краю.
    private var partial: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(complete ? Color.green : Color.orange)
            if !complete {
                Text("Перемещено в Корзину: \(report.moved.count) из \(report.moved.count + report.failed.count + report.refused.count).")
            }
            if !report.failed.isEmpty {
                Text("Не удалось переместить:").foregroundStyle(.secondary)
                pathList(report.failed)
                if report.failed.contains(where: Access.isPermissionProblem) && !Access.hasFullDiskAccess {
                    Button { Access.openFullDiskAccess() } label: {
                        Label("Выдать Uproot полный доступ к диску", systemImage: "lock.open")
                    }
                }
            }
            if !report.refused.isEmpty {
                Text("Системные, пропущены:").foregroundStyle(.secondary)
                pathList(report.refused)
            }
            HStack {
                Button("Открыть Корзину") {
                    NSWorkspace.shared.open(Locations.home.appendingPathComponent(".Trash"))
                }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var complete: Bool { report.failed.isEmpty && report.refused.isEmpty }

    private var title: String {
        guard complete else { return "Удалено не всё" }
        let apps = report.moved.filter { $0.pathExtension == "app" }.count
        if apps == 1 { return "Приложение успешно удалено" }
        if apps > 1 { return "Приложения успешно удалены" }
        return "Выбранные файлы перемещены в Корзину"
    }

    private func pathList(_ urls: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.self) {
                    Text($0.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}
