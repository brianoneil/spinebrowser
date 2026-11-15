import SwiftUI

/// Where Today tabs go after their hours run out. Grouped by day, searchable, one tap to bring back.
struct ArchiveView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var query = ""

    private var groups: [(day: Date, items: [ArchivedTab])] {
        let matches = store.archive.filter { item in
            query.isEmpty || CommandModel.score(query, item.title + " " + (item.host ?? "")) != nil
        }
        let byDay = Dictionary(grouping: matches) { Calendar.current.startOfDay(for: $0.archivedAt) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day, default: []].sorted { $0.archivedAt > $1.archivedAt })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Archive")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .foregroundStyle(p.text)
                Spacer()
                Button("Done") { store.isArchiveOpen = false }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(p.accent)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            archiveTimer
                .padding(.horizontal, 24)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundStyle(p.time)
                TextField("Search the archive", text: $query)
                    .font(Typeface.row)
                    .foregroundStyle(p.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(p.sunken, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if groups.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "Nothing shelved yet" : "No matches")
                        .font(.headline)
                        .foregroundStyle(p.text)
                    Text(query.isEmpty
                         ? "Tabs you don't pin land here when their time is up."
                         : "Try a shorter search.")
                        .font(Typeface.row)
                        .foregroundStyle(p.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.day) { group in
                            SectionLabel(text: group.day.formatted(.relative(presentation: .named)), color: p.time)
                                .padding(.horizontal, 10)
                                .padding(.top, 18)
                                .padding(.bottom, 6)
                            ForEach(group.items) { item in
                                Button {
                                    store.restore(item.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        FaviconView(archived: item, size: 20)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(item.title).font(Typeface.row).foregroundStyle(p.text).lineLimit(1)
                                            Text(item.host ?? item.url.absoluteString)
                                                .font(Typeface.footnote)
                                                .foregroundStyle(p.textSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("Reopen").font(Typeface.footnoteStrong).foregroundStyle(p.accent)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 48)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(p.page)
    }

    /// Auto-archive timing: 6h / 12h / 24h / off.
    private var archiveTimer: some View {
        let options: [(String, Double?)] = [("6 hours", 6), ("12 hours", 12), ("24 hours", 24), ("Never", nil)]
        let current = options.first { $0.1 == store.archiveAfterHours }?.0 ?? "12 hours"
        return Menu {
            ForEach(options, id: \.0) { option in
                Button(option.0) { store.setArchiveAfter(hours: option.1) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.archiveAfterHours == nil
                     ? "Unpinned tabs stay until you close them"
                     : "Unpinned tabs archive after \(current)")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(Typeface.row)
            .foregroundStyle(p.time)
            .frame(minHeight: 32)
        }
    }
}
