import SwiftUI

// The Sources tab itself lives in SourcesView.swift. This file keeps the
// two row components it uses, which are also used by the catalogue
// sheet.

// MARK: - Addon row

struct AddonRow: View {
    let addon: InstalledAddon
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Platform.isMac ? Theme.Spacing.md : Theme.Spacing.sm) {
            // Drag handle / reorder controls.
            VStack(spacing: 2) {
                reorderButton(icon: "chevron.up",   action: onMoveUp)
                reorderButton(icon: "chevron.down", action: onMoveDown)
            }
            // No hover on a touch screen: always visible there.
            .opacity(isHovering || !Platform.isMac ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: isHovering)

            Group {
                if let logoString = addon.manifest.logo, let url = URL(string: logoString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        default: placeholderIcon
                        }
                    }
                } else {
                    placeholderIcon
                }
            }
            .frame(width: Platform.isMac ? 44 : 34, height: Platform.isMac ? 44 : 34)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.Palette.backgroundAlt)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(addon.manifest.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .font(Theme.Font.label(14, weight: .bold))
                        .foregroundStyle(
                            isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary
                        )
                    if Platform.isMac {
                    Text("v\(addon.manifest.version)")
                        .lineLimit(1)
                        .fixedSize()
                        .font(Theme.Font.caption(10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Rectangle().fill(Theme.Palette.backgroundAlt))
                    }
                }
                if !Platform.isMac {
                    // A phone: one line of text instead of the version badge
                    // and the type chips, so the name gets the width.
                    Text((["v\(addon.manifest.version)"] + addon.manifest.types.map(\.capitalized)).joined(separator: " · "))
                        .font(Theme.Font.caption(10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                } else {
                HStack(spacing: 4) {
                    ForEach(addon.manifest.types.prefix(4), id: \.self) { t in
                        Text(t.capitalized)
                            .font(Theme.Font.caption(10))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Rectangle().fill(Theme.Palette.accentSoft))
                    }
                    Text("· \(addon.manifest.resources.joined(separator: " · "))")
                        .font(Theme.Font.caption(10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                }
            }
            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(isEnabled ? "Disable addon" : "Enable addon")

            Menu {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove addon", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 34, height: 34)
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 1)
                )
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func reorderButton(icon: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(
                    action == nil ? Theme.Palette.textQuaternary : Theme.Palette.textSecondary
                )
                .frame(width: 20, height: 16)
        }
        .buttonStyle(.plainRect)
        .disabled(action == nil)
    }

    private var placeholderIcon: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Theme.Palette.accentText)
    }
}

// MARK: - Suggested card

struct SuggestedCard: View {
    let suggestion: SuggestedAddon
    let isInstalled: Bool
    let onAdd: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.Palette.accentSoft)
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Palette.accentText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.name)
                    .font(Theme.Font.label(14, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(suggestion.blurb.localized)
                    .font(Theme.Font.body(12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            FrameButton(title: isInstalled ? "Installed" : "Add",
                        icon: isInstalled ? "checkmark" : "plus",
                        color: isInstalled ? Theme.Palette.success : Theme.Palette.accent,
                        fill: isInstalled ? nil : Theme.Palette.accent,
                        isEnabled: !isInstalled) {
                onAdd()
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 1)
                )
        )
        .onHover { isHovering = $0 }
    }
}

// The app has one button language: `FrameButton` in Components.swift —
// a rectangle with hairline rules, uppercase tracked type, and the
// `onAccent` colour when filled.
//
// The pill-shaped `PrimaryButtonStyle` / `SecondaryButtonStyle` that
// used to live here were the second language. They survived as "shared
// styles kept for compatibility", but they contradicted the design
// system (see Theme.Radius: corners "collapse to sharp") and every
// call site has been migrated. Don't reintroduce them.
