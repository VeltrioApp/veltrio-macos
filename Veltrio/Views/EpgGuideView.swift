import SwiftUI

/// The XMLTV guide as a grid: a row per channel, programmes laid out on a
/// three-hour window that can be moved an hour at a time. Clicking a
/// programme tunes to its channel.
struct EpgGuideView: View {
    let channels: [IptvChannel]

    @Environment(AppStore.self) private var store

    /// Start of the visible window, on the half hour.
    @State private var windowStart = EpgGuideView.halfHour(before: Date())

    private let span: TimeInterval = 3 * 3600
    private let channelColumn: CGFloat = 210
    private let rowHeight: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigation
                .padding(.bottom, Theme.Spacing.md)
            ruler
            Rule()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(channels, id: \.id) { channel in
                    row(channel)
                    Rule(color: Theme.Palette.border)
                }
            }
        }
    }

    // MARK: - window navigation

    private var navigation: some View {
        HStack(spacing: Theme.Spacing.sm) {
            FrameButton(title: "", icon: "chevron.left") { windowStart -= 3600 }
                .help(String(localized: "Earlier"))
            FrameButton(title: "Now", icon: "clock") { windowStart = Self.halfHour(before: Date()) }
            FrameButton(title: "", icon: "chevron.right") { windowStart += 3600 }
                .help(String(localized: "Later"))
            Text(Self.dayFormatter.string(from: windowStart))
                .eyebrow(Theme.Palette.textTertiary, tracking: 2.0)
                .padding(.leading, Theme.Spacing.sm)
            Spacer()
        }
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: channelColumn, height: 22)
            GeometryReader { geo in
                ForEach(0..<6, id: \.self) { i in
                    let t = windowStart.addingTimeInterval(Double(i) * 1800)
                    Text(Self.timeFormatter.string(from: t))
                        .font(Theme.Font.mono(10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .offset(x: geo.size.width * CGFloat(i) / 6 + 4)
                }
            }
            .frame(height: 22)
        }
    }

    // MARK: - rows

    private func row(_ channel: IptvChannel) -> some View {
        HStack(spacing: 0) {
            NavigationLink(value: PlayerDestination(kind: .liveChannel(channel: channel), title: channel.name)) {
                HStack(spacing: 10) {
                    ZStack {
                        Rectangle().fill(Theme.Palette.surface)
                        if let logo = channel.logoUrl, let url = URL(string: logo) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFit().padding(4) }
                            }
                        }
                    }
                    .frame(width: 44, height: 32)
                    Text(channel.name)
                        .font(Theme.Font.label(12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }
                .padding(.trailing, Theme.Spacing.sm)
                .frame(width: channelColumn, height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainRect)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(visible(store.epg.schedule(for: channel))) { p in
                            programmeCell(p, channel: channel, now: context.date)
                                .frame(width: max(2, width(of: p, in: geo.size.width) - 2), height: rowHeight - 8)
                                .offset(x: x(of: p.start, in: geo.size.width), y: 4)
                        }
                        if context.date >= windowStart && context.date <= windowStart.addingTimeInterval(span) {
                            Rectangle().fill(Theme.Palette.accent)
                                .frame(width: 1.5, height: rowHeight)
                                .offset(x: x(of: context.date, in: geo.size.width))
                        }
                    }
                }
            }
            .frame(height: rowHeight)
            .clipped()
        }
    }

    private func programmeCell(_ p: EpgProgramme, channel: IptvChannel, now: Date) -> some View {
        let isOn = p.start <= now && now < p.end
        return NavigationLink(value: PlayerDestination(kind: .liveChannel(channel: channel), title: channel.name)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(Theme.Font.label(11, weight: isOn ? .bold : .semibold))
                    .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text("\(Self.timeFormatter.string(from: p.start)) – \(Self.timeFormatter.string(from: p.end))")
                    .font(Theme.Font.mono(9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Rectangle().fill(isOn ? Theme.Palette.accentSoft : Theme.Palette.surface))
            .overlay(Rectangle().stroke(isOn ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plainRect)
        .help([p.title, p.description].compactMap { $0 }.joined(separator: "\n\n"))
    }

    // MARK: - geometry

    private func visible(_ list: [EpgProgramme]) -> [EpgProgramme] {
        let end = windowStart.addingTimeInterval(span)
        return list.filter { $0.end > windowStart && $0.start < end }
    }

    private func x(of date: Date, in width: CGFloat) -> CGFloat {
        CGFloat(max(0, date.timeIntervalSince(windowStart)) / span) * width
    }

    private func width(of p: EpgProgramme, in width: CGFloat) -> CGFloat {
        let start = max(p.start, windowStart)
        let end = min(p.end, windowStart.addingTimeInterval(span))
        return CGFloat(end.timeIntervalSince(start) / span) * width
    }

    static func halfHour(before date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 1800))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()
}
