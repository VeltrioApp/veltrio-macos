import SwiftUI

/// Live TV the way TV apps lay it out: a numbered channel list on the left
/// with what's on and how far into it, the selected channel large on the
/// right — current programme, its progress, what's next — and a Watch
/// button. Arrow keys move through the list, Return tunes in.
struct LiveTVView: View {
    /// Channels to list (group and search already applied).
    let channels: [IptvChannel]
    /// Channel id → its number in the whole playlist, so numbers don't
    /// shift when a group is picked.
    let numbers: [String: Int]
    let groups: [(name: String, count: Int)]
    @Binding var selectedGroup: String?

    @Environment(AppStore.self) private var store
    @State private var selectedId: String?
    @FocusState private var listFocused: Bool
    @FocusState private var focusedChannel: String?

    private var selected: IptvChannel? {
        channels.first { $0.id == selectedId } ?? channels.first
    }

    /// Narrower than this (a phone), the list alone, full width: a tap
    /// tunes in.
    private static let splitWidth: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            if geo.size.width < Self.splitWidth {
                channelList(tapToPlay: true)
            } else {
                split
            }
        }
    }

    private var split: some View {
        HStack(alignment: .top, spacing: 0) {
            channelList(tapToPlay: false)
                .frame(width: Platform.isTV ? 560 : 380)
                .onChange(of: focusedChannel) { _, id in if let id { selectedId = id } }
            Rule(color: Theme.Palette.border)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            ZStack(alignment: .topLeading) {
                if let channel = selected {
                    // A fresh hero per channel, so changing channel fades the
                    // new one in instead of swapping text in place.
                    LiveChannelHero(channel: channel, number: numbers[channel.id])
                        .id(channel.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 14)),
                            removal: .opacity
                        ))
                }
            }
            .padding(.leading, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The remote: right from any channel reaches Watch, which sits
            // lower than most rows.
            .focusSection()
            .animation(.easeOut(duration: 0.22), value: selected?.id)
        }
    }

    // MARK: - channel list

    private func channelList(tapToPlay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    Button("All channels") { selectedGroup = nil }
                    Divider()
                    ForEach(groups, id: \.name) { g in
                        Button("\(g.name)  (\(g.count))") { selectedGroup = g.name }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text((selectedGroup ?? "All channels").localized)
                            .eyebrow(Theme.Palette.textPrimary, tracking: 2.0)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Text("\(channels.count)")
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.sm)
            Rule()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(channels, id: \.id) { channel in
                            #if os(tvOS)
                            // The remote: focus picks the channel (the panel
                            // follows), a click tunes in.
                            Button { play(channel) } label: {
                                LiveChannelRow(channel: channel, number: numbers[channel.id],
                                               isSelected: !tapToPlay && channel.id == selected?.id)
                            }
                            .buttonStyle(.plainRect)
                            .focused($focusedChannel, equals: channel.id)
                            .id(channel.id)
                            #else
                            LiveChannelRow(channel: channel, number: numbers[channel.id],
                                           isSelected: !tapToPlay && channel.id == selected?.id)
                                .id(channel.id)
                                .if(tapToPlay) { row in
                                    row.onTapGesture { play(channel) }
                                }
                                .if(!tapToPlay) { row in
                                    row.onTapGesture(count: 2) { play(channel) }
                                        .onTapGesture {
                                            selectedId = channel.id
                                            listFocused = true
                                        }
                                }
                            #endif
                        }
                    }
                }
                // On a TV the rows take the focus themselves.
                .focusable(!Platform.isTV)
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.downArrow) { move(by: 1, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { move(by: -1, proxy: proxy); return .handled }
                .onKeyPress(.return) {
                    if let channel = selected { play(channel) }
                    return .handled
                }
            }
        }
        // A Mac's arrow keys go to the list at once; on a TV the focus
        // stays where the remote left it.
        .onAppear { if !Platform.isTV { listFocused = true } }
    }

    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard !channels.isEmpty else { return }
        let index = channels.firstIndex { $0.id == selected?.id } ?? 0
        let next = channels[max(0, min(channels.count - 1, index + step))]
        selectedId = next.id
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next.id, anchor: .center) }
    }

    private func play(_ channel: IptvChannel) {
        NotificationCenter.default.post(
            name: .veltrioPlay,
            object: PlayerDestination(kind: .liveChannel(channel: channel), title: channel.name)
        )
    }
}

// MARK: - row

private struct LiveChannelRow: View {
    let channel: IptvChannel
    let number: Int?
    let isSelected: Bool

    @Environment(AppStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(isSelected ? Theme.Palette.accent : .clear)
                .frame(width: 2)
            Text(number.map { String(format: "%03d", $0) } ?? "—")
                .font(Theme.Font.mono(11, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.Palette.accentText : Theme.Palette.textQuaternary)
                .fixedSize()
                .frame(minWidth: 30, alignment: .leading)
            ChannelLogo(url: channel.logoUrl, name: channel.name)
                .frame(width: 60, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(Theme.Font.label(13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let now = store.epg.current(for: channel) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(now.title)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                            ProgressLine(value: now.progress(at: context.date))
                        }
                    }
                } else if let group = channel.group {
                    Text(group)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.trailing, Theme.Spacing.sm)
        .background(isSelected ? Theme.Palette.surfaceHover : (isHovering ? Theme.Palette.surface : .clear))
        .contentShape(Rectangle())
        .pointerHover { isHovering = $0 }
    }
}

// MARK: - hero

private struct LiveChannelHero: View {
    let channel: IptvChannel
    let number: Int?

    @Environment(AppStore.self) private var store

    /// Picture, title and Watch fit the window without scrolling: the
    /// picture takes at most ~40 % of the height, Watch sits beside the
    /// title, and only the "Up next" list scrolls.
    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = store.epg.current(for: channel, at: context.date)
                let upcoming = store.epg.schedule(for: channel).filter { $0.start > context.date }.prefix(8)
                let stageWidth = min(geo.size.width, 720, max(280, geo.size.height * 0.42) * 16 / 9)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    stage(now: now)
                        .frame(width: stageWidth, height: stageWidth * 9 / 16)
                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        if let now {
                            programme(now, at: context.date)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(channel.name)
                                    .font(Theme.Font.displaySerif(30, weight: .bold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(store.epg.hasGuide ? "No programme information for this channel."
                                                        : "No TV guide for this playlist.")
                                    .font(Theme.Font.body(13))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.md)
                        CTAButton(title: "Watch") { play() }
                            .frame(width: 190)
                    }
                    .frame(maxWidth: 720)
                    if !upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Up next").eyebrow(Theme.Palette.accentText, tracking: 2.4)
                                .padding(.bottom, Theme.Spacing.sm)
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(upcoming)) { p in
                                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                                            Text(Self.time.string(from: p.start))
                                                .font(Theme.Font.mono(12, weight: .semibold))
                                                .foregroundStyle(Theme.Palette.textTertiary)
                                                .frame(width: 52, alignment: .leading)
                                            Text(p.title)
                                                .font(Theme.Font.body(13))
                                                .foregroundStyle(Theme.Palette.textPrimary)
                                                .lineLimit(1)
                                            Spacer()
                                            if let category = p.category {
                                                Text(category).font(Theme.Font.caption(11))
                                                    .foregroundStyle(Theme.Palette.textTertiary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        Rule(color: Theme.Palette.border)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 720)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// 16:9 picture: the programme's still when the guide has one, else
    /// the channel's logo on a quiet backdrop. Live badge and channel in
    /// the corner, as on a TV's info banner.
    private func stage(now: EpgProgramme?) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.Palette.surface)
            if let image = now?.image {
                AsyncImage(url: image) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill().modifier(SlowZoom()) }
                }
            } else {
                ChannelLogo(url: channel.logoUrl, name: channel.name)
                    .padding(60)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: Theme.Spacing.md) {
                HStack(spacing: 6) {
                    LivePulse()
                    Text("LIVE").font(Theme.Font.eyebrow(10, weight: .heavy)).tracking(2.0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Rectangle().fill(.black.opacity(0.55)))
                if let number {
                    Text(String(format: "%03d", number))
                        .font(Theme.Font.mono(12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(channel.name)
                    .font(Theme.Font.label(14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(Theme.Spacing.md)
        }
        .overlay {
            // Play affordance on the picture itself.
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 58, height: 58)
                .background(Circle().fill(.white.opacity(0.9)))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        }
        .clipped()
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { play() }
    }

    private func programme(_ p: EpgProgramme, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.title)
                .font(Theme.Font.displaySerif(30, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            HStack(spacing: Theme.Spacing.md) {
                Text("\(Self.time.string(from: p.start)) – \(Self.time.string(from: p.end))")
                    .font(Theme.Font.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(String(localized: "\(max(1, Int(p.end.timeIntervalSince(date) / 60))) min left"))
                    .font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.accentText)
                if let category = p.category {
                    Text(category).font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            ProgressLine(value: p.progress(at: date))
            if let description = p.description {
                Text(description)
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func play() {
        NotificationCenter.default.post(
            name: .veltrioPlay,
            object: PlayerDestination(kind: .liveChannel(channel: channel), title: channel.name)
        )
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

// MARK: - shared bits

/// The red "on air" dot, breathing.
private struct LivePulse: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Theme.Palette.danger)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Theme.Palette.danger, lineWidth: 1.5).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.8))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// A slow push-in on a still, like a TV channel's programme card.
private struct SlowZoom: ViewModifier {
    @State private var zoomed = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(zoomed ? 1.07 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { zoomed = true }
            }
    }
}

private struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.Palette.hairline)
                Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 2)
    }
}

/// A channel's logo, or its initials when it has none or it fails to load.
struct ChannelLogo: View {
    let url: String?
    let name: String

    var body: some View {
        ZStack {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFit()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
    }

    private var initials: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(Theme.Font.label(13, weight: .bold))
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
