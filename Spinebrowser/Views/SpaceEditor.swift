import SwiftUI

struct SpaceSheetID: Identifiable {
    let id: UUID
}

/// Name a space, give it an emoji, and bind it in one of the seven cloths. The space is the theme:
/// the binding tints its Spine, its Pair bars and its inks, so the preview shows the cloth itself.
struct SpaceEditor: View {
    let spaceID: UUID

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isNaming: Bool

    private static let emoji = ["🪴", "🗂️", "📚", "🏡", "✈️", "🎨", "🧪", "🍳", "💼", "🎧", "🌊", "✳️"]

    var body: some View {
        if let space = store.space(id: spaceID) {
            editor(space)
        }
    }

    private func editor(_ space: Space) -> some View {
        let binding = space.binding
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Edit space")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(p.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { commitName(); dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(p.accent)
                }

                // The cloth itself: a strip of the Spine as this space will wear it.
                HStack(spacing: 12) {
                    Text(space.emoji).font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.isEmpty ? space.name : name)
                            .font(Typeface.spaceTitle)
                            .foregroundStyle(binding.ink(p))
                            .lineLimit(1)
                        Text(binding.label)
                            .font(Typeface.footnote)
                            .foregroundStyle(binding.secondary(p))
                    }
                    Spacer()
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(colors: [binding.tint(p), binding.deep(p)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                )
                .animation(Motion.spring(reduce: reduceMotion), value: binding)
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Name", color: p.textSecondary)
                    TextField("Space name", text: $name)
                        .font(.body)
                        .foregroundStyle(p.text)
                        .focused($isNaming)
                        .doneSubmitLabel()
                        .onSubmit(commitName)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(p.sunken, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Emoji", color: p.textSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(Self.emoji, id: \.self) { glyph in
                            let isSelected = space.emoji == glyph
                            Button {
                                store.library.updateSpace(spaceID) { $0.emoji = glyph }
                            } label: {
                                Text(glyph)
                                    .font(.system(size: 22))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(isSelected ? binding.tint(p) : p.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(binding.ink(p), lineWidth: 1.5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Binding", color: p.textSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                        ForEach(SpaceBinding.allCases) { cloth in
                            BindingSwatch(binding: cloth, isSelected: cloth == binding) {
                                withAnimation(Motion.spring(reduce: reduceMotion)) {
                                    store.library.updateSpace(spaceID) { $0.binding = cloth }
                                }
                            }
                        }
                    }
                    Text("The binding tints this space's Spine, its window bars and its inks.")
                        .font(.footnote)
                        .foregroundStyle(p.textSecondary)
                }

                if store.spaces.count > 1 {
                    Rectangle().fill(p.line).frame(height: 1)
                    Button {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete \(space.name)", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(p.danger)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Delete \(space.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button("Delete space", role: .destructive) {
                            dismiss()
                            withAnimation(Motion.spring(reduce: reduceMotion)) { store.library.deleteSpace(spaceID) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Its tabs move to the archive, where you can bring any of them back.")
                    }
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(p.page.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(p.page)
        .onAppear {
            name = space.name
            // A space made just now waits to be named.
            if space.name == "New space" { isNaming = true }
        }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        store.library.updateSpace(spaceID) { $0.name = name }
    }
}

/// A swatch of bookcloth: its tint-to-deep wash with a dot of its ink, named below.
private struct BindingSwatch: View {
    let binding: SpaceBinding
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [binding.tint(p), binding.deep(p)], startPoint: .top, endPoint: .bottom))
                    Circle().fill(binding.ink(p)).frame(width: 14, height: 14)
                }
                .frame(width: 48, height: 48)
                .overlay {
                    Circle().strokeBorder(isSelected ? binding.ink(p) : p.line, lineWidth: isSelected ? 2 : 1)
                }
                .padding(3)
                .overlay {
                    if isSelected { Circle().strokeBorder(binding.ink(p).opacity(0.35), lineWidth: 1) }
                }
                Text(binding.label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? binding.ink(p) : p.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(binding.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
