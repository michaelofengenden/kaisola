import SwiftUI

/// The pane header's remote-control indicator, reduced to a value.
///
/// The chip answers one security question: which device is driving this
/// terminal from off-machine, and is that authority still live. It is allowed
/// to say less as the pane narrows. It is never allowed to say something
/// meaningless. The one-letter-plus-ellipsis capsule from #305 is what the
/// character floor here exists to prevent: below `minimumLegibleCharacters` the
/// chip drops its text entirely and keeps the identity in the tooltip, the
/// accessibility value, and the detail popover instead.
struct CompanionControllerChip: Equatable {

    /// The three lease bands the header draws apart. `expiring` and `stale` are
    /// the ones a reader has to act on: control is about to end, or the desktop
    /// is still holding a lease the device stopped renewing.
    enum Lease: Equatable {
        case active
        case expiring
        case stale
    }

    /// Three complete presentations. None is a truncation of the one above it:
    /// `compact` drops the name rather than shortening it past legibility.
    enum Layout: Equatable {
        case compact
        case standard
        case expanded
    }

    /// What the header draws at one particular width.
    struct Presentation: Equatable {
        let layout: Layout
        /// `nil` in `compact`, where only the device glyph and the state glyph
        /// are drawn.
        let title: String?
    }

    /// One labelled fact in the inspectable detail popover.
    struct DetailRow: Equatable {
        let label: String
        let value: String
    }

    /// The paired device's display name, never shortened by this type.
    let deviceName: String
    /// A short device-id tail, set only when another paired device answers to
    /// the same display name. Two phones both called "iPhone" must not read as
    /// one indistinguishable capsule across two panes.
    let deviceTag: String?
    let lease: Lease
    /// Whole seconds until the lease expires, floored at zero.
    let secondsRemaining: Int

    // MARK: - Identity

    /// The full identity. Everything that may be shortened is derived from
    /// this; the tooltip, the accessibility value, and the popover use it whole.
    var identity: String {
        guard let deviceTag, !deviceTag.isEmpty else { return deviceName }
        return "\(deviceName) · \(deviceTag)"
    }

    // MARK: - Wording

    /// The state as one word, for the expanded capsule.
    var stateWord: String {
        switch lease {
        case .active: "controlling"
        case .expiring: "expiring"
        case .stale: "stale"
        }
    }

    /// The state as a noun phrase, for the popover's Control row.
    var stateTitle: String {
        switch lease {
        case .active: "Live"
        case .expiring: "Expiring"
        case .stale: "Stale"
        }
    }

    /// The state as a sentence, for the tooltip and the accessibility value.
    var stateSentence: String {
        switch lease {
        case .active:
            "Control is live; it ends in \(secondsRemaining)s unless the device renews."
        case .expiring:
            "Control ends in \(secondsRemaining)s unless the device renews."
        case .stale:
            "The lease expired. The desktop is taking control back."
        }
    }

    // MARK: - Assistive presentations

    var accessibilityLabel: String { "Remote control" }

    /// The full identity survives here at every width, which is the point of
    /// the compact presentation being allowed to drop text at all.
    var accessibilityValue: String { "\(identity). \(stateSentence)" }

    var tooltip: String { "Controlled from \(identity)\n\(stateSentence)" }

    var detailRows: [DetailRow] {
        var rows = [
            DetailRow(label: "Device", value: identity),
            DetailRow(label: "Control", value: stateTitle),
            DetailRow(label: "Lease", value: stateSentence),
        ]
        if deviceTag != nil {
            rows.append(
                DetailRow(
                    label: "Why the suffix",
                    value: "Another paired device uses the same name, "
                        + "so the chip shows this one's device id."
                )
            )
        }
        return rows
    }

    // MARK: - Width

    /// Header furniture the chip never competes with: the focus glyph, the
    /// status glyph, the trailing pane controls, and the shortest pane title
    /// worth drawing at all.
    static let reservedHeaderWidth: CGFloat = 210
    /// Capsule chrome around the text: device glyph, state glyph, padding.
    static let capsuleChromeWidth: CGFloat = 38
    /// Average advance of the capsule face at scale 1, rounded up so the budget
    /// under-promises rather than overflows the header.
    static let characterWidth: CGFloat = 6
    /// Below this many characters a name stops being a name. The chip goes
    /// compact instead of drawing "i…".
    static let minimumLegibleCharacters = 6
    /// A pathological device name may not eat the whole header just because the
    /// pane is wide.
    static let maximumDrawnCharacters = 44

    /// The presentation this chip earns at `paneWidth`, with `textScale`
    /// carrying the reader's Larger Text setting: bigger type buys fewer
    /// characters, so a large-text pane steps down a presentation rather than
    /// truncating harder.
    func presentation(paneWidth: CGFloat, textScale: CGFloat = 1) -> Presentation {
        let scale = max(0.8, textScale)
        let room = paneWidth - (Self.reservedHeaderWidth + Self.capsuleChromeWidth) * scale
        let affordable = Int((room / (Self.characterWidth * scale)).rounded(.down))
        let budget = min(affordable, Self.maximumDrawnCharacters)
        let identity = identity
        let expanded = "\(identity) · \(stateWord)"
        if budget >= expanded.count { return Presentation(layout: .expanded, title: expanded) }
        if budget >= identity.count { return Presentation(layout: .standard, title: identity) }
        guard let clipped = Self.clip(identity, to: budget) else {
            return Presentation(layout: .compact, title: nil)
        }
        return Presentation(layout: .standard, title: clipped)
    }

    func layout(paneWidth: CGFloat, textScale: CGFloat = 1) -> Layout {
        presentation(paneWidth: paneWidth, textScale: textScale).layout
    }

    /// `text` shortened to `budget` characters, or nil when what would be left
    /// is no longer worth drawing.
    private static func clip(_ text: String, to budget: Int) -> String? {
        guard budget > minimumLegibleCharacters else { return nil }
        var kept = String(text.prefix(budget - 1))
        // End on a word when one is close by, so the capsule reads
        // "Michael's…" rather than "Michael's iPh…".
        if let space = kept.lastIndex(of: " "),
           kept.distance(from: space, to: kept.endIndex) <= 5,
           kept.distance(from: kept.startIndex, to: space) >= minimumLegibleCharacters {
            kept = String(kept[kept.startIndex ..< space])
        }
        kept = kept.trimmingCharacters(in: .whitespaces)
        guard kept.count >= minimumLegibleCharacters else { return nil }
        return kept + "…"
    }

    /// macOS does not scale a fixed-point system font on its own, so the chip
    /// scales its own font and its width budget by the same factor.
    static func textScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.86
        case .small: 0.92
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.36
        case .accessibility1: 1.6
        case .accessibility2: 1.9
        case .accessibility3: 2.2
        case .accessibility4: 2.5
        case .accessibility5: 2.8
        @unknown default: 1
        }
    }

    // MARK: - State

    static func lease(expiresAt: Int64, now: Int64, ttlMilliseconds: Int64) -> Lease {
        let remaining = expiresAt - now
        if remaining <= 0 { return .stale }
        // The device renews after a third of the TTL, so anything inside the
        // last third means at least one renewal has already gone missing.
        if remaining <= max(1, ttlMilliseconds / 3) { return .expiring }
        return .active
    }

    /// Colour and glyph are chosen together: the state stays readable without
    /// colour, which matters for an indicator that reports authority.
    var tone: KaisolaStatusTone {
        switch lease {
        case .active: .working
        case .expiring: .needsYou
        case .stale: .failed
        }
    }

    var symbolName: String {
        switch lease {
        case .active: "dot.radiowaves.left.and.right"
        case .expiring: "clock"
        case .stale: "exclamationmark.triangle.fill"
        }
    }
}

/// A chip's identity plus the lease clock it is derived against.
///
/// The header holds this and re-derives the chip as the clock moves, so
/// "expiring" and "stale" appear on time instead of waiting for the next
/// renewal to republish the lease.
struct CompanionControllerChipSource: Equatable {
    let deviceName: String
    let deviceTag: String?
    let expiresAt: Int64
    let ttlMilliseconds: Int64

    init(
        deviceName: String,
        deviceTag: String? = nil,
        expiresAt: Int64,
        ttlMilliseconds: Int64 = CompanionTerminalControl.leaseTTLMilliseconds
    ) {
        self.deviceName = deviceName
        self.deviceTag = deviceTag
        self.expiresAt = expiresAt
        self.ttlMilliseconds = ttlMilliseconds
    }

    func chip(now: Int64) -> CompanionControllerChip {
        let remaining = max(0, expiresAt - now)
        return CompanionControllerChip(
            deviceName: deviceName,
            deviceTag: deviceTag,
            lease: CompanionControllerChip.lease(
                expiresAt: expiresAt,
                now: now,
                ttlMilliseconds: ttlMilliseconds
            ),
            secondsRemaining: Int((remaining + 999) / 1_000)
        )
    }

    /// Resolve one live lease against the paired-device roster.
    ///
    /// A missing `status` is the whole answer for release, expiry, revocation,
    /// and a dropped connection alike: all four remove the lease, so the
    /// indicator cannot outlive the authority it reports. A status whose device
    /// has already left the roster still shows, because the lease is what makes
    /// the chip security-relevant, not the display name.
    static func resolve(
        status: CompanionTerminalControlStatus?,
        pairedDevices: [CompanionPairedDeviceRecord],
        ttlMilliseconds: Int64 = CompanionTerminalControl.leaseTTLMilliseconds
    ) -> CompanionControllerChipSource? {
        guard let status else { return nil }
        let named = pairedDevices.first { $0.deviceId == status.deviceID }?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = named.isEmpty ? "Paired device" : named
        let sharing = pairedDevices.filter {
            $0.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }
        return CompanionControllerChipSource(
            deviceName: name,
            deviceTag: sharing.count > 1 ? deviceTag(status.deviceID) : nil,
            expiresAt: status.expiresAt,
            ttlMilliseconds: ttlMilliseconds
        )
    }

    /// The tail of a device id, upper-cased, as the disambiguator between two
    /// devices with the same name.
    static func deviceTag(_ deviceID: String) -> String? {
        let compact = deviceID.filter { $0.isLetter || $0.isNumber }
        guard compact.count >= 2 else { return nil }
        return String(compact.suffix(4)).uppercased()
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}

/// The header capsule itself.
///
/// It re-derives its chip once a second so an unrenewed lease turns amber and
/// then red on the header rather than silently sitting on "controlling", and it
/// is a button: the presentation the pane is too narrow for is always one click
/// away in the popover.
struct CompanionControllerChipView: View {
    let source: CompanionControllerChipSource
    let paneWidth: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetail = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            capsule(source.chip(now: CompanionControllerChipSource.milliseconds(context.date)))
        }
    }

    private func capsule(_ chip: CompanionControllerChip) -> some View {
        let scale = CompanionControllerChip.textScale(for: dynamicTypeSize)
        let presentation = chip.presentation(paneWidth: paneWidth, textScale: scale)
        let tint = chip.tone.foregroundColor
        return Button {
            showsDetail.toggle()
        } label: {
            HStack(spacing: 3 * scale) {
                Image(systemName: "iphone")
                    .font(.system(size: 9 * scale, weight: .semibold))
                if let title = presentation.title {
                    Text(title)
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .lineLimit(1)
                }
                Image(systemName: chip.symbolName)
                    .font(.system(size: 7 * scale, weight: .bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chip.tone.backgroundColor, in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(chip.lease == .active ? 0.22 : 0.55), lineWidth: 0.5)
            }
            // The capsule reports the width the presentation asked for and
            // keeps it. A squeezed header shortens the pane title instead:
            // who holds control outranks a title the project name already said.
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(chip.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityValue(chip.accessibilityValue)
        .accessibilityHint("Shows which device holds this terminal's control lease.")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) { detail(chip) }
    }

    private func detail(_ chip: CompanionControllerChip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Remote control", systemImage: "iphone")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chip.tone.foregroundColor)
            ForEach(chip.detailRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}
