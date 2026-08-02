import AppKit
import SwiftUI

/// The model picker behind the composer's model chip: a provider rail beside a
/// searchable, ⌘-numbered, starrable list.
///
/// The rail has exactly the providers this chat can actually reach — favourites
/// and the one agent driving it. An ACP conversation is bound to a single
/// adapter process, so a rail of every vendor would be four-fifths dead
/// buttons; changing agent means a new chat, which is what the footer says.
struct AcpModelPickerView: View {
    let identity: QuietIdentity
    let agentName: String
    let models: [AcpSessionInfo.Model]
    let currentID: String?
    let favorites: Set<String>
    let select: (String) -> Void
    let toggleFavorite: (String) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var favoritesOnly = false
    @FocusState private var searchFocused: Bool

    private var choices: [AcpModelChoice] {
        AcpModelPicker.choices(
            models: models,
            currentID: currentID,
            favorites: favorites,
            query: query,
            favoritesOnly: favoritesOnly
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            list
        }
        .frame(width: 356, height: 328)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model picker")
        .accessibilityIdentifier("acp.modelPicker")
    }

    // MARK: - Provider rail

    private var rail: some View {
        VStack(spacing: 6) {
            railButton(
                isSelected: favoritesOnly,
                label: favoritesOnly ? "Show all models" : "Show favourites only",
                identifier: "acp.modelPicker.favoritesFilter"
            ) {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(favoritesOnly ? KaisolaStatusTone.needsYou.foregroundColor : Color.secondary)
            } action: {
                favoritesOnly.toggle()
            }

            railButton(
                isSelected: !favoritesOnly,
                label: agentName,
                identifier: "acp.modelPicker.provider"
            ) {
                QuietIdentityMarkView(identity: identity, size: 15)
            } action: {
                favoritesOnly = false
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 40)
        .background(.quaternary.opacity(0.28))
    }

    private func railButton<Mark: View>(
        isSelected: Bool,
        label: String,
        identifier: String,
        @ViewBuilder mark: () -> Mark,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            mark()
                .frame(width: 26, height: 26)
                .background(
                    isSelected ? AnyShapeStyle(.quaternary.opacity(0.9)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.rowIconRadius + 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search models…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .accessibilityLabel("Search models")
                    .accessibilityIdentifier("acp.modelPicker.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if choices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(choices) { choice in
                            row(choice)
                        }
                    }
                    .padding(6)
                }
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        .onAppear { searchFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("acp.modelPicker.empty")
    }

    private var emptyMessage: String {
        if models.isEmpty {
            return "\(agentName) did not advertise any selectable models for this session."
        }
        if favoritesOnly, favorites.isEmpty {
            return "No favourites yet. Star a model to keep it at the top."
        }
        return "No model matches “\(query)”."
    }

    @ViewBuilder
    private func row(_ choice: AcpModelChoice) -> some View {
        HStack(spacing: 4) {
            selectButton(choice)
            favoriteButton(choice)
        }
        .background(
            choice.isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)
        )
    }

    @ViewBuilder
    private func selectButton(_ choice: AcpModelChoice) -> some View {
        let button = Button {
            select(choice.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).font(.callout).lineLimit(1)
                    if let subtitle = choice.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if choice.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if let shortcut = choice.shortcut {
                    Text("⌘\(shortcut)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.name)
        .accessibilityValue(choice.isCurrent ? "Current model" : "")
        .accessibilityIdentifier("acp.modelPicker.model.\(choice.id)")

        if let shortcut = choice.shortcut, let key = Self.digitKey(shortcut) {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }

    private func favoriteButton(_ choice: AcpModelChoice) -> some View {
        Button {
            toggleFavorite(choice.id)
        } label: {
            Image(systemName: choice.isFavorite ? "star.fill" : "star")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(
                    choice.isFavorite ? KaisolaStatusTone.needsYou.foregroundColor : Color.secondary
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.isFavorite ? "Remove from favourites" : "Keep at the top of this list")
        .accessibilityLabel(
            choice.isFavorite ? "Unfavourite \(choice.name)" : "Favourite \(choice.name)"
        )
        .accessibilityIdentifier("acp.modelPicker.favorite.\(choice.id)")
    }

    private var footer: some View {
        Button {
            dismiss()
            NSApp.sendAction(#selector(KaisolaMacAppDelegate.openSettings(_:)), to: nil, from: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                Text("Agents in Settings…")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("A chat is bound to one agent — add or configure agents in Settings, then start a new chat")
        .accessibilityLabel("Open Settings, Agents")
        .accessibilityIdentifier("acp.modelPicker.settings")
    }

    private static func digitKey(_ value: Int) -> KeyEquivalent? {
        guard (1...9).contains(value), let character = String(value).first else { return nil }
        return KeyEquivalent(character)
    }
}
