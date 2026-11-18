import SwiftUI

/// The playlist's channels beside the live player, to zap without leaving
/// it. The channel on screen is highlighted and scrolled into view.
struct PlayerChannelList: View {
    let current: IptvChannel
    let onSelect: (IptvChannel) -> Void
    let onClose: () -> Void

    @Environment(AppStore.self) private var store
    @State private var filter = ""

    private var channels: [(number: Int, channel: IptvChannel)] {
        let all = store.iptvChannels.enumerated().map { (number: $0.offset + 1, channel: $0.element) }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.channel.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Channels").eyebrow(.white.opacity(0.9), tracking: 2.4)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plainRect)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 70)
            .padding(.bottom, Theme.Spacing.sm)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                TextField(String(localized: "Search channels"), text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Rectangle().fill(.white.opacity(0.08)))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(channels, id: \.channel.id) { item in
                            row(item.number, item.channel)
                                .id(item.channel.id)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ number: Int, _ channel: IptvChannel) -> some View {
        let isCurrent = channel.id == current.id
        return Button { onSelect(channel) } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Rectangle()
                    .fill(isCurrent ? Theme.Palette.accent : .clear)
                    .frame(width: 2)
                Text(String(format: "%03d", number))
                    .font(Theme.Font.mono(10, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.Palette.accent : .white.opacity(0.45))
                    .frame(width: 28, alignment: .leading)
                ChannelLogo(url: channel.logoUrl, name: channel.name)
                    .frame(width: 44, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(Theme.Font.label(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let now = store.epg.current(for: channel) {
                        Text(now.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.trailing, Theme.Spacing.md)
            .background(isCurrent ? Color.white.opacity(0.1) : .clear)
        }
        .buttonStyle(.plainRect)
    }
}
