import ChippyCore
import SwiftUI

/// Chippy's static look for a state, sized like the old placeholder icon.
struct StateIcon: View {
    let state: ChippyState
    var size: CGFloat = 18
    var sleeping = false

    var body: some View {
        ChipmunkView(state: state, sleeping: sleeping).frame(width: size * 1.4, height: size * 1.4)
    }
}

/// Incoming content: fades in with a small scale from the top, a beat after the shape starts growing (#214: no blur).
/// Reduce Motion: a short fade, no scale.
struct Reveal: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(reduce || on ? 1 : 0.96, anchor: .top)
            .onAppear { withAnimation(Motion.fade(Motion.enter.delay(delay), reduce: reduce)) { on = true } }
    }
}

extension View {
    func reveal(_ delay: Double) -> some View { modifier(Reveal(delay: delay)) }
}

/// Dates for a countdown: every `step` seconds until `end`, then one last at `end`, so the view stops ticking once
/// the deadline has passed. Without an `end` it is a single entry.
struct CountdownSchedule: TimelineSchedule {
    let end: Date?
    let step: TimeInterval
    func entries(from start: Date, mode: Mode) -> [Date] {
        guard let end, end > start else { return [start] }
        // Covers the whole deadline whatever its length (a 120s question at 0.5s is 240 ticks), then stops.
        let n = Int((end.timeIntervalSince(start) / step).rounded(.up))
        return (0..<n).map { start.addingTimeInterval(Double($0) * step) } + [end]
    }
}

/// "times out in Ns" under the card title (#86): a card that is still open (a hovered one included) never hides
/// that the hook will give up and the terminal take over.
struct TimeoutNote: View {
    let createdAt: Date
    let timeout: TimeInterval
    var body: some View {
        TimelineView(CountdownSchedule(end: createdAt.addingTimeInterval(timeout), step: 1)) { ctx in
            let left = Int(NeedsMeFold.timeLeft(createdAt: createdAt, timeout: timeout, now: ctx.date).rounded(.up))
            if left > 0 {
                Text("times out in \(left)s").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                    .accessibilityLabel("Times out to the terminal in \(CountLabel.counted(left, "second"))")
            }
        }
    }
}

/// Small count of waiting items on the collapsed notch ("9+" caps it). Folded approvals or questions (#86) make it
/// the needs-you badge: orange, a gentle pulse (none under Reduce Motion), and a ring draining to the moment the hook
/// gives up and the terminal takes over.
struct CountBadge: View {
    let text: String
    /// Never wider than this (the wing it sits in): the text shrinks to fit.
    let maxWidth: CGFloat
    /// Tap opens the waiting list (#53). The hit area is larger than the 16pt capsule.
    var onTap: () -> Void = {}
    var needsYou = false
    var dotLabel = "Finished threads waiting, nothing needs you"
    var deadline: (start: Date, end: Date)? = nil
    /// Whose request is next (the rank-first needs-you one), when a count alone would not say (#89).
    var mark: SessionIdentity? = nil
    var markRepo: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    @ViewBuilder var body: some View {
        if text.isEmpty { dot } else { counted }
    }

    /// Only finished items wait (#101): a plain dot, no number. Same tap target and wing limit as the count.
    private var dot: some View {
        Circle().fill(.white.opacity(0.92)).frame(width: 8, height: 8)
            .reveal(0.08)
            .frame(minWidth: min(24, max(maxWidth, 16)), maxWidth: max(maxWidth, 16), minHeight: 24)
            .contentShape(Rectangle())
            .pressFeedback().onTapGesture(perform: onTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dotLabel)
            .accessibilityHint("Opens the list of everything waiting")
            .accessibilityAddTraits(.isButton)
    }

    private var counted: some View {
        // Ring and VoiceOver label are both computed from this tick's date, so they never disagree or go stale.
        TimelineView(CountdownSchedule(end: needsYou ? deadline?.end : nil, step: reduceMotion ? 1 : 0.5)) { ctx in
            badge(now: ctx.date)
        }
        // Runs on appear (so a badge that arrives already needing you pulses) and again when either input changes.
        .task(id: PulseInput(needsYou: needsYou, reduceMotion: reduceMotion)) { await MainActor.run { updatePulse() } }
    }

    private struct PulseInput: Equatable { let needsYou: Bool; let reduceMotion: Bool }

    private func badge(now: Date) -> some View {
        let left = deadline.map { NeedsMeFold.timeLeft(createdAt: $0.start, timeout: $0.end.timeIntervalSince($0.start), now: now) }
        let fraction = deadline.map { NeedsMeFold.fractionLeft(createdAt: $0.start, timeout: $0.end.timeIntervalSince($0.start), now: now) } ?? 1
        let showMark = mark != nil && maxWidth >= 34
        let label = needsYou
            ? "\(text) waiting, needs you" + (showMark ? mark.map { ", next from \(markRepo ?? "one repo"), \($0.spokenShort)" } ?? "" : "") + (left.map { ", times out to the terminal in \(CountLabel.counted(Int($0.rounded(.up)), "second"))" } ?? "")
            : "\(text) finished waiting"
        let pulsing = needsYou && pulse && !reduceMotion
        return HStack(spacing: 3) {
            if showMark, let mark { IdentityMark(identity: mark, size: 11) }
            Text(text).font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(needsYou ? .white : .black)
                .lineLimit(1).minimumScaleFactor(0.8) // 10pt x 0.8 = 8pt floor (C41)
        }
            .padding(.horizontal, 4).frame(minWidth: 16, maxWidth: max(maxWidth, 16), minHeight: 16)
            .background(Capsule().fill(needsYou ? Color.orange : .white.opacity(0.92)))
            .overlay {
                if needsYou, deadline != nil { Capsule().trim(from: 0, to: fraction).stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).padding(-2.5) }
            }
            .scaleEffect(pulsing ? 1.12 : 1)
            .opacity(pulsing ? 0.85 : 1)
            .reveal(0.08)
            // A real, larger tap target (24pt), never wider than the wing / tab the badge lives in.
            .frame(minWidth: min(24, max(maxWidth, 16)), maxWidth: max(maxWidth, 16), minHeight: 24)
            .contentShape(Rectangle())
            .pressFeedback().onTapGesture(perform: onTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Opens the list of everything waiting")
            .accessibilityAddTraits(.isButton)
    }

    /// Start the pulse, or end it for good: a repeating animation only stops when the value is set again under a
    /// transaction that carries a different animation.
    private func updatePulse() {
        if needsYou && !reduceMotion {
            withAnimation(Motion.pulse) { pulse = true }
        } else {
            withTransaction(Transaction(animation: Motion.instant)) { pulse = false }
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var box: MetricsBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    /// The shape's resting size for the current state. The window never changes; only this does.
    private var target: CGSize {
        var s = box.metrics.size(for: model.density, resting: model.resting, tall: model.tall, contentHeight: box.contentHeight)
        if model.density == .collapsed && box.hover && !reduceMotion { s.width += 6 }
        return s
    }

    private var radius: CGFloat { model.density == .expanded ? 20 : 12 }

    var body: some View {
        let size = target
        ZStack(alignment: .top) {
            NotchShape(radius: radius).fill(.black)
                .frame(width: size.width, height: size.height)
            // Content keeps its final width and height at all times (no text reflow while the shape grows)
            // and is revealed by the shape's edge.
            ZStack(alignment: .top) {
                content
                    .id(model.density)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.fade(Motion.exit, reduce: reduceMotion))))
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .animation(nil, value: size)
            // The mask is outside the `animation(nil)` above, so it springs with the shape and the edge reveals the content.
            .mask(NotchShape(radius: radius).frame(width: size.width, height: size.height).frame(maxHeight: .infinity, alignment: .top))
            icon(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(motion, value: size)
        .animation(motion, value: radius)
        .animation(motion, value: model.density)
        .scaleEffect(pressed && model.density == .collapsed && !reduceMotion ? 0.97 : 1, anchor: .top)
        .animation(Motion.press, value: pressed)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleOpen() }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
    }

    /// One chipmunk for every density, so it never pops: it rides the shape's left edge and scales between
    /// the glance size and the header size.
    private func icon(_ size: CGSize) -> some View {
        let m = box.metrics
        let big: CGFloat = 28 * 1.4
        let small = NotchMetrics.glanceIcon
        let open = model.density == .expanded
        return ChipmunkView(state: model.state, sleeping: model.asleep, asleepSince: model.asleepSince).frame(width: big, height: big)
            .scaleEffect(open ? 1 : small / big, anchor: .topLeading)
            .offset(x: iconX(open: open, small: small, size: size), y: open ? m.height + 2 : iconY(small: small, size: size))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    /// Wings: the left edge. Tab: centred when collapsed, left of the glance text when compact.
    private func iconX(open: Bool, small: CGFloat, size: CGSize) -> CGFloat {
        if open { return 16 }
        guard box.metrics.isTab || model.resting else { return 10 }
        return model.density == .compact ? 12 : (size.width - small) / 2
    }

    /// Resting is always a tab (never wings): under the camera on a notch, a flat pill at top-centre without one.
    private func iconY(small: CGFloat, size: CGSize) -> CGFloat {
        let m = box.metrics
        if model.resting && !m.hasNotch { return max(0, (size.height - small) / 2) }
        if m.isTab || model.resting { return m.band + (NotchMetrics.tabHeight - small) / 2 }
        return (m.band - small) / 2
    }

    private func report(_ h: CGFloat) {
        DispatchQueue.main.async { if h > 0, abs(box.contentHeight - h) > 0.5 { box.contentHeight = h } }
    }

    /// One spring for the shape (slight settle, no bounce); a near-instant change when the user asked for reduced motion.
    private var motion: Animation {
        Motion.or(Motion.shape, reduce: reduceMotion)
    }

    /// Glance chip: who finished (repo · branch), so several threads can be told apart, and that repo's identity mark.
    /// One pick for both, so the text and the mark never describe different sessions.
    private var compactChip: (text: String, mark: SessionIdentity?) {
        // Only when the icon says "needs you" too: live work (icon: working) wins over the chip text.
        if model.state == .needsYou, let t = model.terminalItems.last, model.pending.isEmpty, t.at >= (model.doneItems.last?.at ?? .distantPast) {
            return (t.glance(repo: model.repoLabel(cwd: t.cwd, project: t.project).text), model.identity(cwd: t.cwd, project: t.project))
        }
        guard let d = model.doneItems.last else { return (model.state.title, nil) }
        return (d.glance(showReply: model.showReplyInGlance, repo: model.repoLabel(cwd: d.cwd, project: d.project).text), model.identity(cwd: d.cwd, project: d.project))
    }

    static let terminalCardCap = 2
    /// Session rows in the peek, so the card's measured height stays within its cap.
    static let sessionRowCap = GlanceMetrics.rowCap // rows are GlanceMetrics.rowHeight each

    /// Live glance (#90): one line per session, needs-you first.
    @ViewBuilder private var glanceRows: some View {
        // Live glance (#90): one line per session, working first. The word is the tool's category only, never its input.
        // One timeline for the rows: a word with no new event for 90s (Esc, crash) falls back to the state at read time.
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let ordered = model.glanceSessions(now: ctx.date) // re-ranked every tick, needs-you always first
            ForEach(ordered.prefix(Self.sessionRowCap)) { row in
                let line = model.glanceLine(for: row, now: ctx.date)
                GlanceRow(label: model.repoLabel(cwd: row.cwd, project: row.project), mark: model.identity(cwd: row.cwd, project: row.project), text: line.text, live: line.live)
            }
            if ordered.count > Self.sessionRowCap {
                Text("\(CountLabel.counted(ordered.count - Self.sessionRowCap, "more session"))").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// Terminal chips as cards (at most `terminalCardCap`, then a "N more" row, so the panel's measured height stays within its cap beside done cards).
    @ViewBuilder private var terminalCards: some View {
        ForEach(model.terminalItems.reversed().prefix(Self.terminalCardCap)) { t in TerminalCard(item: t, repo: model.repoLabel(cwd: t.cwd, project: t.project).text, mark: model.identity(cwd: t.cwd, project: t.project)) { model.dismissTerminal(t.sessionId) }.reveal(0.12) }
        let hidden = model.terminalItems.count - Self.terminalCardCap
        if hidden > 0 {
            Text("\(hidden) more asked in terminal").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).reveal(0.12)
        }
    }

    @ViewBuilder private func doneCards(limit: Int, full: Bool = false) -> some View {
        ForEach(model.doneItems.reversed().prefix(limit)) { d in DoneCard(item: d, repo: model.repoLabel(cwd: d.cwd, project: d.project).text, mark: model.identity(cwd: d.cwd, project: d.project), full: full) { model.dismissDone(d.sessionId) }.reveal(0.12) }
    }

    /// Content beside the camera: icon in the left wing, text in the right wing, nothing under the cutout.
    @ViewBuilder
    var content: some View {
        let m = box.metrics
        switch model.density {
        case .collapsed:
            // The icon is drawn once, by NotchView.icon. Finished items waiting show a small count.
            if let badge = model.badge ?? (model.badgeDot ? "" : nil), m.isTab {
                VStack(spacing: 0) {
                    Color.clear.frame(height: m.band)
                    let off = (m.width + NotchMetrics.glanceIcon) / 2 + NotchMetrics.badgeGap // past the centred icon
                    HStack(spacing: 0) {
                        Color.clear.frame(width: off)
                        CountBadge(text: badge, maxWidth: m.width - off - 8, onTap: { model.openBadge() },
                                   needsYou: model.badgeNeedsYou, dotLabel: model.badgeDotLabel, deadline: model.foldedDeadline, mark: model.badgeIdentity, markRepo: model.badgeRepo) // stays inside the tab
                        Spacer(minLength: 0)
                    }.frame(height: NotchMetrics.tabHeight)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if let badge = model.badge ?? (model.badgeDot ? "" : nil) {
                let wing = m.wing(for: .collapsed)
                HStack(spacing: 0) {
                    Color.clear.frame(width: wing)
                    Color.clear.frame(width: m.width)
                    CountBadge(text: badge, maxWidth: wing - 8, onTap: { model.openBadge() },
                                   needsYou: model.badgeNeedsYou, dotLabel: model.badgeDotLabel, deadline: model.foldedDeadline, mark: model.badgeIdentity, markRepo: model.badgeRepo).frame(width: wing)
                }
                .frame(height: m.band, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear.frame(height: m.band)
            }
        case .compact where m.isTab:
            // No room beside the camera: the glance lives in a tab under it (icon is drawn by NotchView.icon).
            let chip = compactChip
            VStack(spacing: 0) {
                Color.clear.frame(height: m.band)
                HStack(spacing: 6) {
                    Color.clear.frame(width: NotchMetrics.glanceIcon + 12)
                    if let m = chip.mark { IdentityMark(identity: m, size: 12) }
                    Text(chip.text).font(.caption.bold()).foregroundStyle(.white).lineLimit(1).truncationMode(.tail).help(chip.text)
                    if model.doneItems.count + model.terminalItems.count > 1 {
                        Text("+" + CountLabel.short(model.doneItems.count + model.terminalItems.count - 1)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            .accessibilityLabel("\(model.doneItems.count + model.terminalItems.count - 1) more")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 10).frame(height: NotchMetrics.tabHeight)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .reveal(0.08)
        case .compact where !m.compactFits:
            Color.clear.frame(height: m.band) // gap too small: the collapsed pill only
        case .compact:
            let wing = m.wing(for: .compact)
            let chip = compactChip
            HStack(spacing: 0) {
                Color.clear.frame(width: wing)
                Color.clear.frame(width: m.width)
                HStack(spacing: 6) {
                    if let m = chip.mark { IdentityMark(identity: m, size: 12) }
                    Text(chip.text)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail).help(chip.text)
                    if model.doneItems.count + model.terminalItems.count > 1 {
                        Text("+" + CountLabel.short(model.doneItems.count + model.terminalItems.count - 1)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            .accessibilityLabel("\(model.doneItems.count + model.terminalItems.count - 1) more")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(width: wing)
            }
            .frame(height: m.band, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .top)
            .reveal(0.08)
        case .expanded:
            VStack(alignment: .leading, spacing: NotchMetrics.cardSpacing) {
                Spacer().frame(height: box.metrics.height + NotchMetrics.cameraInset)
                HStack(spacing: 10) {
                    Color.clear.frame(width: 28 * 1.4, height: 28 * 1.4) // where NotchView.icon sits
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.headerTitle).font(.headline.monospacedDigit()).foregroundStyle(.white)
                        if !model.listOpen, let r = model.shownPending, let t = model.knownTimeout(for: r) { TimeoutNote(createdAt: r.createdAt, timeout: t) }
                    }
                    Spacer(minLength: 0)
                    if model.waitingItems.count > 1 && !model.listOpen {
                        ChipButton(title: "All " + CountLabel.short(model.waitingItems.count), kind: .neutral) { model.openList() }
                            .accessibilityLabel("All, \(model.waitingItems.count) waiting")
                            .accessibilityHint("Opens the list of everything waiting")
                    }
                    Button(action: box.openMenu) {
                        Image(systemName: "gearshape.fill").font(.callout).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help("Chippy menu")
                    .accessibilityLabel("Chippy menu")
                }
                .frame(height: NotchMetrics.cardHeaderHeight)
                .reveal(0.08)
                if model.listOpen {
                    WaitingListView(model: model).reveal(0.12)
                } else if let req = model.shownPending {
                    if req.questions != nil {
                        QuestionCard(req: req, repo: model.repoLabel(cwd: req.cwd, project: req.project).text, mark: model.identity(cwd: req.cwd, project: req.project), initial: model.partials[req.id] ?? PartialAnswers(),
                                     progress: { model.savePartial(req.id, step: $0, answers: $1, byUser: $2) },
                                     send: { model.answer(req.id, selections: $0, texts: $1) }, handBack: { model.handBack(req.id) },
                                     freeText: model.freeTextReplyEnabled, focusReset: model.replyFocusReset, initialTexts: model.draftTexts(req.id),
                                     draft: { model.setDraft(req.id, question: $0, text: $1) }, replyFocus: { model.setReplyFieldFocused($0, id: req.id) }).id(req.id).reveal(0.12)
                    } else if let plan = req.plan {
                        PlanCard(req: req, plan: plan, repo: model.repoLabel(cwd: req.cwd, project: req.project).text, mark: model.identity(cwd: req.cwd, project: req.project), startExpanded: model.expandedPlans.contains(req.id), expand: { model.setPlanExpanded(req.id, $0) }) { model.resolve(req.id, $0) }.id(req.id).reveal(0.12)
                    } else {
                        ApprovalCard(req: req, repo: model.repoLabel(cwd: req.cwd, project: req.project).text, mark: model.identity(cwd: req.cwd, project: req.project)) { model.resolve(req.id, $0) }.reveal(0.12)
                    }
                } else if let d = model.shownDone {
                    DoneCard(item: d, repo: model.repoLabel(cwd: d.cwd, project: d.project).text, mark: model.identity(cwd: d.cwd, project: d.project), full: true) { model.dismissDone(d.sessionId) }.reveal(0.12)
                } else if model.restOpen, let digest = model.awayDigest {
                    // Digest rows and what is below them scroll together once taller than the room left under the header.
                    ScrollWhenTall(maxHeight: NotchMetrics.maxExpandedHeight - NotchMetrics.shapePadding - NotchMetrics.cameraInset - box.metrics.height - NotchMetrics.cardHeaderHeight - 2 * NotchMetrics.cardSpacing) {
                        VStack(alignment: .leading, spacing: NotchMetrics.cardSpacing) {
                        AwayDigestView(model: model, digest: digest).reveal(0.12) // #92: on top; it covers its own chips and Recent
                        // Everything the digest does not cover stays reachable below, compact.
                        let covered = Set(digest.rows.map(\.sessionId))
                        ForEach(model.terminalItems.reversed().filter { !covered.contains($0.sessionId) }.prefix(2)) { t in
                            TerminalCard(item: t, repo: model.repoLabel(cwd: t.cwd, project: t.project).text, mark: model.identity(cwd: t.cwd, project: t.project)) { model.dismissTerminal(t.sessionId) }.reveal(0.12)
                        }
                        ForEach(model.doneItems.reversed().filter { !covered.contains($0.sessionId) }.prefix(1)) { d in
                            DoneCard(item: d, repo: model.repoLabel(cwd: d.cwd, project: d.project).text, mark: model.identity(cwd: d.cwd, project: d.project), full: false) { model.dismissDone(d.sessionId) }.reveal(0.12)
                        }
                        // Recent entries the digest rows do not already show, compact.
                        let recentLeft = model.recent.items.filter { !covered.contains($0.sessionId) }
                        if !recentLeft.isEmpty {
                            RecentListView(items: Array(recentLeft.prefix(3)), label: { $0.label.text }, mark: { model.identity(recent: $0) }).reveal(0.12)
                        }
                            glanceRows
                        }
                    }
                } else if model.restOpen {
                    // #139: a count header, then Needs you, Working and Done. Rows scroll once taller than the room left under the header.
                    ScrollWhenTall(maxHeight: NotchMetrics.maxExpandedHeight - NotchMetrics.shapePadding - NotchMetrics.cameraInset - box.metrics.height - NotchMetrics.cardHeaderHeight - 2 * NotchMetrics.cardSpacing) {
                        PanelSectionsView(model: model).reveal(0.12)
                    }
                } else {
                    terminalCards
                    doneCards(limit: model.tall ? 1 : 3, full: model.tall)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .background(GeometryReader { g in Color.clear.onAppear { report(g.size.height) }.onChange(of: g.size.height) { report($0) } })
        }
    }
}

/// Measured like QuestionCard: natural height until it would exceed `maxHeight`, then a scroll region of exactly that height.
struct ScrollWhenTall<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var h: CGFloat = 0
    var body: some View {
        let inner = content().frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: QuestionBodyHeight.self, value: g.size.height) })
        Group {
            if h > maxHeight { ScrollView { inner }.frame(height: maxHeight) } else { inner }
        }
        .onPreferenceChange(QuestionBodyHeight.self) { h = $0 }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ApprovalCard: View {
    let req: PendingRequest
    /// The resolved repo label, as the list rows show it; the project name until given.
    var repo: String? = nil
    /// Stable per-repo identity (#89), shown before the repo name.
    var mark: SessionIdentity? = nil
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(req.branch.map { "\(repo ?? req.project) · \($0)" } ?? (repo ?? req.project))
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
                .identityLead(mark)
            if let p = req.lastPrompt, !p.isEmpty {
                Text("“\(p)”").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            if let intent = req.intent {
                // Agent-written text is unverified: small, secondary, captioned. The raw command below is the dominant element.
                VStack(alignment: .leading, spacing: 1) {
                    if intent.fromAgent { Text("Claude says (unverified):").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                    Text(intent.text).font(.caption).foregroundStyle(.white.opacity(intent.fromAgent ? 0.65 : 0.85)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("\(req.toolName) wants to run").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            Text(req.detail.isEmpty ? req.toolName : ApprovalIntent.preview(req.detail))
                .font(.system(.callout, design: .monospaced).weight(.medium)).foregroundStyle(.white)
                .lineLimit(12) // backstop only: preview() already bounds rows and keeps head, tail and a hidden-count marker
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(req.cwd).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.head).help(req.cwd)
            TourCaption(sessionId: req.sessionId, step: .approval)
            HStack(spacing: 8) {
                ChipButton(title: "Allow", hint: "\(ShortcutKeys.prefix)Y", kind: .primary) { decide(.allow) }
                ChipButton(title: "Deny", hint: "\(ShortcutKeys.prefix)N", kind: .destructive) { decide(.deny) }
                Spacer(minLength: 0)
                ChipButton(title: "Always allow this", hint: "\(ShortcutKeys.prefix)A", kind: .quiet) { decide(.always) }
            }
            .padding(.top, 2)
        }
    }
}

/// ExitPlanMode (#91): the plan Claude proposes, capped, with Approve / Keep planning. Plan text is sanitised in core
/// (`PlanProposal`), agent-written so captioned unverified, and only ever on screen. Expanding it pins the card (never folds).
struct PlanCard: View {
    let req: PendingRequest
    let plan: PlanProposal
    /// The resolved repo label, as the list rows show it; the project name until given.
    var repo: String? = nil
    /// Stable per-repo identity (#89), shown before the repo name.
    var mark: SessionIdentity? = nil
    let expand: (Bool) -> Void
    let decide: (Decision) -> Void
    @State private var expanded: Bool
    @State private var bodyHeight: CGFloat = 0
    /// Reduce Motion: "Show more" swaps in place, no animated expand.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Chrome around the rows (header, captions, buttons) is about 250pt; the rest of the panel is the rows' budget.
    static let maxBodyHeight: CGFloat = NotchMetrics.maxExpandedHeight - 250

    init(req: PendingRequest, plan: PlanProposal, repo: String? = nil, mark: SessionIdentity? = nil, startExpanded: Bool = false, expand: @escaping (Bool) -> Void, decide: @escaping (Decision) -> Void) {
        self.req = req; self.plan = plan; self.repo = repo; self.mark = mark; self.expand = expand; self.decide = decide
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        let v = plan.visible(expanded: expanded)
        VStack(alignment: .leading, spacing: 6) {
            Text(req.branch.map { "\(repo ?? req.project) · \($0)" } ?? (repo ?? req.project))
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
                .identityLead(mark)
            if let p = req.lastPrompt, !p.isEmpty {
                Text("“\(p)”").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            Text("Claude says (unverified):").font(.caption2).foregroundStyle(.white.opacity(0.6))
            let rows = VStack(alignment: .leading, spacing: 3) {
                Text(plan.title ?? "Proposed plan").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true) // no line limit: rows are capped in core, so nothing is ellipsized silently
                ForEach(Array(v.shown.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if plan.truncated || v.hidden > 0 {
                    let more = v.hidden > 0 ? "\(CountLabel.counted(v.hidden, "more line"))" : nil
                    let tail = plan.truncated ? "plan continues in the terminal" : nil
                    Text(ApprovalIntent.marker([more, tail].compactMap { $0 }.joined(separator: " · "))).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
                let removed = plan.hiddenRemoved(expanded: expanded)
                if removed > 0 {
                    Text("\(CountLabel.counted(removed, "hidden character")) removed").font(.caption2.monospacedDigit()).foregroundStyle(.orange.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: QuestionBodyHeight.self, value: g.size.height) })
            // Measured like QuestionCard: scrolls at a fixed height once taller, so the buttons never leave the panel.
            Group {
                if bodyHeight > Self.maxBodyHeight { ScrollView { rows }.frame(height: Self.maxBodyHeight) } else { rows }
            }
            .onPreferenceChange(QuestionBodyHeight.self) { bodyHeight = $0 }
            HStack(spacing: 6) {
                if plan.stepCount > 0 { Text(CountLabel.counted(plan.stepCount, "step")).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5)) }
                if let f = plan.fileName { Text(f).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle).help(f) }
            }
            Text(req.cwd).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.head).help(req.cwd)
            HStack(spacing: 8) {
                ChipButton(title: plan.truncated ? "Approve (partly shown)" : "Approve", kind: .primary) { decide(.allow) }
                    .help(plan.truncated ? "Approve the part shown (click only: the plan continues in the terminal)"
                          : plan.canExpand && !expanded ? "Show more to approve with \(ShortcutKeys.prefix)Y"
                          : "Approve (\(ShortcutKeys.prefix)Y)")
                ChipButton(title: "Keep planning", kind: .destructive) { decide(.deny) }
                    .help("Keep planning (\(ShortcutKeys.prefix)N)")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            if plan.canExpand {
                ChipButton(title: expanded ? "Show less" : "Show more", kind: .quiet) {
                    expand(!expanded) // reading is engagement: pins so the card cannot fold away mid-read; the hotkey needs it
                    withAnimation(reduceMotion ? nil : Motion.expand) { expanded.toggle() }
                }
            }
        }
    }
}

/// Drawn by hand (system bordered buttons vanish in a non-key panel). Press scales to 0.96, hover lifts, 28pt tall
/// with a larger hit area than it draws.
struct ChipButton: View {
    enum Kind { case primary, destructive, neutral, quiet }
    let title: String
    var hint: String? = nil
    let kind: Kind
    var disabled = false
    var isDefault = false // Return triggers it
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).monospacedDigit() // "All 12" keeps its width as the count changes
                if let hint { Text(hint).font(.caption2).opacity(0.85) } // quiet 0.6 x 0.85 = 0.51 (C39)
            }
        }
            .buttonStyle(ChipStyle(kind: kind, hover: hover && !disabled, disabled: disabled))
            .disabled(disabled)
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            .onHover { hover = $0 }
    }
}

/// Press feedback for plain icon and text buttons (#C19): scale on press, a dim instead under Reduce Motion.
/// Driven by `isPressed`, so keyboard selection (which never presses) does not animate (#208).
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// The same feedback for a row that opens on `onTapGesture`. The pointer-down state comes from a zero-distance drag
/// that runs alongside the tap, so only a real press shows it; arrow/Return selection never does (#208).
/// `dimOnly` dims instead of scaling, for rows that hold their own buttons: a scaled row would move those buttons under
/// a stationary pointer. `enabled: false` adds nothing (a row with no row-level tap).
struct PressFeedback: ViewModifier {
    var scale: CGFloat = 0.98
    var dimOnly = false
    var enabled = true
    /// `@GestureState` resets itself when the gesture is cancelled, so a row cannot stay shrunk.
    @GestureState private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if enabled {
            let dims = dimOnly || reduceMotion
            content
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
                .scaleEffect(pressed && !dims ? scale : 1)
                .opacity(pressed && dims ? (dimOnly ? 0.8 : 0.6) : 1)
                .animation(Motion.press, value: pressed)
        } else {
            content
        }
    }
}

extension View {
    func pressFeedback(scale: CGFloat = 0.98, dimOnly: Bool = false, enabled: Bool = true) -> some View {
        modifier(PressFeedback(scale: scale, dimOnly: dimOnly, enabled: enabled))
    }

    /// A 24pt-tall, 24pt-wide hit frame around a view drawn `drawn`pt tall (C27). The extra height is given back with a
    /// negative padding, so the layout, and so every settled row height, stays as drawn. Attach the tap or Button after it.
    /// `below` grows the target downward only, for a control directly under a row it must not cover.
    func hitTarget24(drawn: CGFloat, below: Bool = false) -> some View {
        let inset = max(0, (24 - drawn) / 2)
        if below {
            return AnyView(padding(.bottom, inset * 2).frame(minWidth: 24, minHeight: 24, alignment: .top).contentShape(Rectangle()).padding(.bottom, -inset * 2))
        }
        return AnyView(padding(.vertical, inset).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()).padding(.vertical, -inset))
    }
}

struct ChipStyle: ButtonStyle {
    let kind: ChipButton.Kind
    let hover: Bool
    /// Disabled draws a neutral grey pill with dimmed text (#213), not a faded kind colour.
    var disabled = false
    /// Reduce Motion drops the press scale (movement); the fill colour still animates.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color {
        if disabled { return Color.white.opacity(0.12) }
        switch kind {
        case .primary: return Color.green.opacity(hover ? 0.95 : 0.8)
        case .destructive: return Color.red.opacity(hover ? 0.32 : 0.2)
        case .neutral: return Color.white.opacity(hover ? 0.22 : 0.14)
        case .quiet: return Color.white.opacity(hover ? 0.1 : 0)
        }
    }
    private var text: Color {
        if disabled { return .white.opacity(0.5) }
        switch kind {
        case .primary: return .black
        case .destructive: return Color(red: 1, green: 0.55, blue: 0.5)
        case .neutral: return .white
        case .quiet: return .white.opacity(0.6)
        }
    }

    private var quietLead: CGFloat { kind == .quiet ? 12 : 0 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(kind == .quiet ? .regular : .semibold)).foregroundStyle(text)
            // Quiet has no visible leading padding so its label lines up with the card text (#213); its hover pill and
            // hit area still reach 12pt to the left, outside the layout.
            .padding(.leading, kind == .quiet ? 0 : 12).padding(.trailing, 12).frame(minHeight: 28)
            .background(Capsule().fill(fill).padding(.leading, kind == .quiet ? -12 : 0))
            .padding(4).padding(.leading, quietLead).contentShape(Rectangle()).padding(.leading, -quietLead).padding(-4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .animation(Motion.hover, value: hover)
    }
}

/// Claude's own multiple-choice question. Pick an option per question; the last pick sends the answers.
private struct QuestionBodyHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct QuestionCard: View {
    let req: PendingRequest
    /// The resolved repo label, as the list rows show it; the project name until given.
    var repo: String? = nil
    /// Stable per-repo identity (#89), shown before the repo name.
    var mark: SessionIdentity? = nil
    /// Progress kept by the model, so leaving this card (to the list) and coming back resumes it.
    let progress: (Int, [String: Set<String>], Bool) -> Void // the Bool: a real user change (false: re-seed or disappear)
    /// The card stays up only for `.refused`.
    let send: ([String: Set<String>], [String: String]) -> NotchModel.Answered
    let handBack: () -> Void
    /// Experimental free-text reply (#94): a field on single-select questions, off unless the setting is on.
    var freeText = false
    let draft: (String, String) -> Void
    let replyFocus: (Bool) -> Void
    /// Changes when AppKit dropped the field's focus behind SwiftUI's back; resets `fieldFocused` so the next click re-focuses.
    var focusReset = 0
    @FocusState private var fieldFocused: Bool
    /// Typed text per question text; replaces the selection for that question. Memory only (the model keeps the drafts).
    @State private var texts: [String: String]
    @State private var step: Int
    /// Why Return did nothing on the field (empty, too long, one line), shown under it on the step where it happened.
    @State private var hint: String?
    /// Chosen labels per question text.
    @State private var answers: [String: Set<String>]
    @State private var lastToggle: (index: Int, at: Date)?
    @State private var sent = false
    @State private var leadExpanded = false
    @State private var bodyHeight: CGFloat = 0
    private static let maxBodyHeight: CGFloat = 330

    init(req: PendingRequest, repo: String? = nil, mark: SessionIdentity? = nil, initial: PartialAnswers = PartialAnswers(), progress: @escaping (Int, [String: Set<String>], Bool) -> Void = { _, _, _ in },
         send: @escaping ([String: Set<String>], [String: String]) -> NotchModel.Answered, handBack: @escaping () -> Void,
         freeText: Bool = false, focusReset: Int = 0, initialTexts: [String: String] = [:], draft: @escaping (String, String) -> Void = { _, _ in }, replyFocus: @escaping (Bool) -> Void = { _ in }) {
        self.req = req; self.repo = repo; self.mark = mark; self.progress = progress; self.send = send; self.handBack = handBack
        self.freeText = freeText; self.focusReset = focusReset; self.draft = draft; self.replyFocus = replyFocus
        _texts = State(initialValue: initialTexts)
        _step = State(initialValue: min(initial.step, max((req.questions?.count ?? 1) - 1, 0)))
        _answers = State(initialValue: initial.answers)
    }

    @ViewBuilder private func questionBody(_ q: AskQuestion, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead = req.leadIn, !lead.isEmpty {
                Text(lead).font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(leadExpanded ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hitTarget24(drawn: 13) // one caption2 line, at least
                    .pressFeedback().onTapGesture { leadExpanded.toggle() }
            }
            Text(count > 1 ? "\(q.header.isEmpty ? "Question" : q.header) · \(step + 1) of \(count)" : (q.header.isEmpty ? "Claude asks" : q.header))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            Text(q.question).font(.caption.bold()).foregroundStyle(.white).lineLimit(3)
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                let on = q.multiSelect && answers[q.question]?.contains(o.label) == true
                HStack(alignment: .top, spacing: 8) {
                    if q.multiSelect {
                        Image(systemName: on ? "checkmark.square.fill" : "square").font(.caption)
                            .foregroundStyle(on ? Color.accentColor : .white.opacity(0.5)).padding(.top, 1)
                    }
                    if i < 9 { Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).padding(.top, 1) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.label).font(.caption.bold()).foregroundStyle(.white)
                        if !o.description.isEmpty { Text(o.description).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(3) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 24) // a one-line option was 22pt: 24pt target (C27)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: on ? 0.26 : 0.18)))
                .animation(nil, value: on) // hotkey-driven: instant (#208)
                .contentShape(Rectangle())
                .pressFeedback().onTapGesture { pick(i) } // press only: `on` stays instant (#208)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if freeText, !q.multiSelect { replyField(q) }
        }
    }

    /// Never focused by Chippy: only a click puts the cursor here, so no keystroke meant for the terminal lands in it.
    /// While focused: Return sends, Esc only drops focus (the draft stays), card hotkeys stand down (AppDelegate).
    @ViewBuilder private func replyField(_ q: AskQuestion) -> some View {
        let text = texts[q.question] ?? ""
        let tooLong = text.trimmingCharacters(in: .whitespacesAndNewlines).count > NotchModel.freeTextLimit
        VStack(alignment: .leading, spacing: 2) {
            TextField("Or type a reply", text: Binding(get: { texts[q.question] ?? "" }, set: { setText($0, q) }))
                .textFieldStyle(.plain).font(.caption).foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit { submitText(q) }
                .onExitCommand { fieldFocused = false } // Esc: leave the field first, never close the card or lose the draft
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: fieldFocused ? 0.26 : 0.18)))
                .accessibilityLabel("Type a reply")
                .accessibilityIdentifier(NotchPanel.replyFieldMarker)
            if let msg = hint ?? (tooLong ? NotchModel.freeTextProblem(text) : nil) {
                Text(msg).font(.caption2).foregroundStyle(.orange)
            }
        }
        .onChange(of: fieldFocused) { replyFocus($0) }
        .onChange(of: focusReset) { _ in fieldFocused = false }
        .onDisappear { replyFocus(false) }
    }

    private func setText(_ new: String, _ q: AskQuestion) {
        // A newline or tab cannot be sent and Return submits: each becomes a space (words stay apart), then the text is kept as typed.
        let t = String(String.UnicodeScalarView(new.unicodeScalars.map { (NotchModel.lineBreaks.contains($0.value) || $0 == "\t") ? " " : $0 }))
        texts[q.question] = t.isEmpty ? nil : t
        draft(q.question, t)
        hint = nil
        progress(step, answers, true) // typing is engagement: pins the card
        // Typed text replaces the selection, but only real text: spaces alone must not clear a pick.
        if NotchModel.validFreeText(t) != nil, answers[q.question] != nil { answers[q.question] = nil }
    }

    private func submitText(_ q: AskQuestion) {
        guard !sent else { return }
        let t = texts[q.question] ?? ""
        if NotchModel.validFreeText(t) == nil {
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(answers[q.question] ?? []).isEmpty { fieldFocused = false; advance(); return } // a pick stands
            hint = NotchModel.freeTextProblem(t); return
        }
        fieldFocused = false
        advance()
    }

    /// Pinned below the scrolling options so it never scrolls away.
    @ViewBuilder private func multiFooter(_ q: AskQuestion, _ count: Int) -> some View {
        let empty = (answers[q.question] ?? []).isEmpty
        HStack {
            Text("Pick one or more").font(.caption2).foregroundStyle(.white.opacity(0.5))
            Spacer()
            ChipButton(title: step + 1 >= count ? "Done" : "Next", kind: .primary, disabled: empty, isDefault: true) { advance() }
                .accessibilityHint(empty ? "Choose at least one option" : "")
        }
    }

    var body: some View {
        let qs = req.questions ?? []
        let q = qs[min(step, qs.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 0).onChange(of: freeText) { on in // flag turned off mid-card: drop typed text so Return behaves as with no draft
                guard !on else { return }
                for k in texts.keys { draft(k, "") }
                texts = [:]; hint = nil; fieldFocused = false
            }
            Text(req.branch.map { "\(repo ?? req.project) · \($0)" } ?? (repo ?? req.project))
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
                .identityLead(mark)
            if let p = req.lastPrompt, !p.isEmpty {
                Text("You asked: \(p)").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            // Short card: hugs its content. Tall one: this part scrolls at a FIXED height (a flexible one would
            // fill whatever the panel offers and the card would keep growing), like the done card.
            // Measured, not ViewThatFits + maxHeight: a flexible container fills the 330pt it is offered and
            // centres the content, leaving dead space above and below a short question.
            let content = questionBody(q, qs.count)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: QuestionBodyHeight.self, value: g.size.height) })
            Group {
                if bodyHeight > Self.maxBodyHeight { ScrollView { content }.frame(height: Self.maxBodyHeight) } else { content }
            }
            .onPreferenceChange(QuestionBodyHeight.self) { bodyHeight = $0 }
            if q.multiSelect { multiFooter(q, qs.count) }
            ChipButton(title: "Answer in terminal", kind: .quiet) { if !sent { sent = true; handBack() } }
            TourCaption(sessionId: req.sessionId, step: .question)
        }
        .onChange(of: step) { fieldFocused = false; replyFocus(false); hint = nil; leadExpanded = false; lastToggle = nil; ShortcutBus.steps.send((req.id, $0)); progress($0, answers, true) }
        .onChange(of: answers) { progress(step, $0, false) } // every selection is saved at once; pinning is pick()'s job, so a re-seed never pins
        .onDisappear { if !sent { progress(step, answers, false) } } // leaving the card keeps what was answered
        .onAppear { if step > 0 { ShortcutBus.steps.send((req.id, step)) } }
        .onReceive(ShortcutBus.events) { e in
            // Keys take the same path as a tap, for this card only.
            guard e.requestId == req.id, case .option(let n) = e.action,
                  let i = ShortcutGate.optionIndex(forKey: n, optionCount: q.options.count) else { return }
            pick(i)
        }
    }

    /// The one answer path for taps and keys: the `sent` guard and multi-question stepping live here.
    /// Single-select picks and moves on; multi-select toggles and waits for Done/Next.
    private func pick(_ index: Int) {
        let qs = req.questions ?? []
        guard !sent, !qs.isEmpty else { return } // a double-click or key repeat must not answer the next question too
        let q = qs[min(step, qs.count - 1)]
        guard q.options.indices.contains(index) else { return }
        fieldFocused = false; replyFocus(false) // a pick moves on: the next question's field must start unfocused
        hint = nil
        let label = q.options[index].label
        progress(step, answers, true) // a tap or key is an interaction (it pins the card) even when the pick changes nothing
        if q.multiSelect {
            // A double-click or a stuck key must not toggle the same option on and straight back off.
            if let l = lastToggle, l.index == index, Date().timeIntervalSince(l.at) < 0.25 { return }
            lastToggle = (index, Date())
            var set = answers[q.question] ?? []
            if !set.insert(label).inserted { set.remove(label) }
            answers[q.question] = set
        } else {
            texts[q.question] = nil; draft(q.question, "") // a picked option replaces what was typed
            answers[q.question] = [label]
            advance()
        }
    }

    private func advance() {
        let qs = req.questions ?? []
        guard !sent, !qs.isEmpty else { return }
        let q = qs[min(step, qs.count - 1)]
        let typed = freeText && !q.multiSelect && texts[q.question].map { NotchModel.validFreeText($0) != nil } == true
        guard typed || !(answers[q.question] ?? []).isEmpty else { return } // multi-select needs at least one
        if step + 1 < qs.count { step += 1 } else {
            sent = true
            if send(answers, freeText ? texts.filter { k, v in qs.contains { $0.question == k && !$0.multiSelect } && NotchModel.validFreeText(v) != nil } : [:]) == .refused { sent = false }
        }
    }
}

struct DoneCard: View {
    let item: DoneItem
    /// The resolved repo label, as the list rows show it; the project name until given.
    var repo: String? = nil
    /// Stable per-repo identity (#89), shown before the repo name.
    var mark: SessionIdentity? = nil
    var full = false
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.identityLine(repo: repo ?? item.project) + (item.asksYou ? " · waiting for your reply" : " · finished"))
                .font(.caption.bold()).foregroundStyle(item.asksYou ? Color.orange : .white)
                .identityLead(mark)
            if full, let p = item.prompt, !p.isEmpty {
                Text("You asked: \(p)").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            let reply = full && item.decision != nil ? item.replyWithoutDecision : item.reply
            SummaryView(reply: reply, decision: full ? item.decision : nil, compact: !full)
                .id(reply)
            TourCaption(sessionId: item.sessionId, step: .done)
            HStack {
                Text(item.files == 0 ? "No file edits" : "\(CountLabel.counted(item.files, "file")) · +\(item.added) −\(item.removed)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if TerminalJump.available(item.host) {
                    OpenTerminalButton(host: item.host, onOpened: dismiss)
                }
                ChipButton(title: "Dismiss", kind: .neutral, action: dismiss)
            }
        }
    }
}

/// The one summary component (#98b), used by the finished card (glance list and opened). Hierarchy: outcome line, then the
/// decision Claude needs, then the rest folded behind "Show details". Light markdown only; raw markers never show.
/// Recent rows hold no reply text by design (PDPA #30), so they do not use this.
struct SummaryView: View {
    var decision: String? = nil
    /// Glance list: the outcome line only, no controls.
    var compact = false
    /// From SummaryMarkdown's 16-entry reply cache, so re-created views do not re-parse.
    private let doc: SummaryMarkdown.Doc?
    /// Shown when the parser yields no doc (e.g. "---", an empty fence, a table): the raw text, clipped, never blank.
    private let fallback: String?
    @State private var open = false
    @State private var detailsHeight: CGFloat = 0
    static let maxDetailsHeight: CGFloat = 240

    init(reply: String?, decision: String? = nil, compact: Bool = false) {
        self.decision = decision; self.compact = compact
        self.doc = SummaryMarkdown.doc(reply)
        let t = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.fallback = t.isEmpty ? nil : String(t.prefix(600)) + (t.count > 600 ? "…" : "")
    }

    private func text(_ runs: [SummaryMarkdown.Run], size: Font = .caption, bold: Bool = false) -> Text {
        runs.reduce(Text("")) { acc, r in
            switch r {
            case .text(let s): return acc + Text(s).font(size).fontWeight(bold ? .semibold : .regular)
            case .bold(let s): return acc + Text(s).font(size).fontWeight(.semibold)
            case .code(let s): return acc + Text(s).font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
            }
        }
    }

    private func block(_ b: SummaryMarkdown.Block) -> some View {
        Group {
            switch b {
            case .paragraph(let r), .heading(let r): text(r).foregroundColor(.white.opacity(0.85))
            case .ordered(let n, let r):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(n).").font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.5))
                    text(r).foregroundColor(.white.opacity(0.85))
                }
            case .bullet(let r):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").font(.caption).foregroundColor(.white.opacity(0.5))
                    text(r).foregroundColor(.white.opacity(0.85))
                }
            case .code(let c):
                Text(c).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85))
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private var detailsBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array((doc?.details ?? []).enumerated()), id: \.offset) { _, b in block(b) }
        }.textSelection(.enabled)
    }

    var body: some View {
        let d = doc
        VStack(alignment: .leading, spacing: 6) {
            if d == nil, let raw = fallback {
                Text(raw).font(.caption).foregroundColor(.white.opacity(0.95))
                    .lineLimit(compact ? 6 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if let d, !d.outcome.isEmpty {
                text(d.outcome).foregroundColor(.white.opacity(0.95))
                    .lineLimit(compact ? 3 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !compact, let dec = decision {
                Text("Needs your call: \(dec)").font(.caption.bold()).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !compact, let d, !d.details.isEmpty {
                Button { open.toggle(); if !open { detailsHeight = 0 } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text(open ? "Hide details" : "Show details").font(.caption2)
                    }.foregroundStyle(.white.opacity(0.6)).hitTarget24(drawn: 13) // 24pt target, layout unchanged (C27)
                }.buttonStyle(PressStyle())
                .accessibilityLabel(open ? "Hide details" : "Show details")
                if open {
                    // Measured, not ViewThatFits + maxHeight: that flexible frame claims the full 240pt it is offered,
                    // leaving a blank gap under a short body. Invisible until measured, so no first-frame jump.
                    let content = detailsBody
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in Color.clear.preference(key: QuestionBodyHeight.self, value: g.size.height) })
                    Group {
                        if detailsHeight > Self.maxDetailsHeight { ScrollView { content }.frame(height: Self.maxDetailsHeight) } else { content }
                    }
                    .opacity(detailsHeight > 0 ? 1 : 0)
                    .onPreferenceChange(QuestionBodyHeight.self) { detailsHeight = $0 }
                }
            }
        }
    }
}

/// A question or approval that went to the terminal. Repo name only, never the question or command (PDPA, #30).
struct TerminalCard: View {
    let item: TerminalItem
    var repo: String? = nil
    /// Stable per-repo identity (#89), shown before the repo name.
    var mark: SessionIdentity? = nil
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.glance(repo: repo ?? item.project)).font(.caption.bold()).foregroundStyle(.white.opacity(0.85)).identityLead(mark)
            HStack {
                Text("Claude is waiting for you there").font(.caption2).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if TerminalJump.available(item.host) { OpenTerminalButton(host: item.host, onOpened: dismiss) }
                ChipButton(title: "Dismiss", kind: .neutral, action: dismiss)
            }
        }
    }
}

/// "Open terminal" with visible feedback: if the host app can't be brought forward the button says so
/// instead of appearing to do nothing.
struct OpenTerminalButton: View {
    let host: HostInfo?
    /// Fixed wording (the terminal rows say "Jump to terminal"); nil names the app ("Open Orca").
    var title: String? = nil
    var kind: ChipButton.Kind = .neutral
    var onOpened: () -> Void = {}
    @State private var feedback: JumpFeedback.Text?
    @State private var busy = false
    @State private var token = 0

    /// The source app's real name ("Orca", "Terminal", "iTerm2"); "terminal" when unknown.
    private var appName: String {
        guard let pid = host?.pid, let app = NSRunningApplication(processIdentifier: pid),
              let name = app.localizedName, !name.isEmpty else { return "terminal" }
        return name
    }

    var body: some View {
        ChipButton(title: feedback?.title ?? title ?? "Open \(appName)", hint: feedback?.hint, kind: feedback != nil ? .neutral : kind) {
            guard !busy else { return }
            busy = true; feedback = nil; token += 1
            let mine = token
            TerminalJump.open(host) { v in
                busy = false
                feedback = JumpFeedback.text(for: v, appName: appName)
                if feedback == nil { onOpened() } // landed, or landed but unconfirmed: both count as opened (see JumpFeedback)
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if token == mine { feedback = nil } } }
            }
        }
        .help(feedback?.help ?? "")
    }
}

/// Flat top edge (flush with the screen), rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat = 14

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Cubic corners with longer handles than a circular arc (0.5523) ease curvature in and out like a continuous corner.
        // Endpoints stay `radius` from the corner, so the silhouette never leaves the rect.
        let handle = radius * 0.68
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX, y: rect.maxY - radius + handle),
                   control2: CGPoint(x: rect.maxX - radius + handle, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                   control1: CGPoint(x: rect.minX + radius - handle, y: rect.maxY),
                   control2: CGPoint(x: rect.minX, y: rect.maxY - radius + handle))
        p.closeSubpath()
        return p
    }
}

/// While you were away (#92): repo, status and age per session, no reply, prompt or question text (PDPA #30). A row with a live
/// chip jumps to it; a Recent-only row offers Open. Dismiss moves the finished ones to Recent.
struct AwayDigestView: View {
    @ObservedObject var model: NotchModel
    let digest: AwayDigest.Result

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("WHILE YOU WERE AWAY (\(digest.total))").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).tracking(0.6)
                    Spacer(minLength: 0)
                    ChipButton(title: "Dismiss", kind: .neutral) { model.dismissAwayDigest() }
                        .accessibilityHint("Moves the finished threads to Recent")
                }
                .accessibilityAddTraits(.isHeader)
                ForEach(digest.rows) { row in rowView(row, now: ctx.date) }
                if digest.hidden > 0 { Text("+\(digest.hidden) more").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55)).padding(.leading, 10) }
            }
        }
    }

    private func status(_ r: DigestRow) -> String {
        DigestWindowRows.statusText(r.status)
    }

    private func rowView(_ r: DigestRow, now: Date) -> some View {
        let age = WaitingList.age(since: r.at, now: now)
        let name = r.worktree.map { "\(r.repo) / \($0)" } ?? r.repo
        let content = HStack(spacing: 10) {
            Image(systemName: r.status == .needsYou ? "exclamationmark.circle.fill" : "checkmark.circle")
                .font(.caption).foregroundStyle(r.status == .needsYou ? Color.orange : .white.opacity(0.5)).frame(width: 18)
            IdentityMark(identity: model.identity(row: r), size: 14)
            Text(name).font(.caption.bold()).foregroundStyle(.white).lineLimit(1).truncationMode(.middle).help(name)
            Text(status(r)).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            Spacer(minLength: 8)
            Text(age).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 10).frame(minHeight: 32)
        .accessibilityElement(children: .ignore) // one element, one label (age included once), the hint on it
        .accessibilityLabel("\(name), \(status(r)) \(age) ago")
        .accessibilityHint(r.target != nil ? "Opens it" : "")
        return HStack(spacing: 4) {
            if let t = r.target {
                Button { model.activate(t) } label: { content.contentShape(Rectangle()) }.buttonStyle(PressStyle(scale: 0.98))
            } else {
                content
                if TerminalJump.available(r.host) { OpenTerminalButton(host: r.host) }
            }
        }
    }
}

/// Recent (#85): the last finished threads after their chip went away. Repo, age and an Open button only; never the
/// reply, prompt, question or command (PDPA #30). `RecentItem` cannot hold them.
struct RecentListView: View {
    let items: [RecentItem]
    /// The one resolved repo label, as the list rows show it.
    var label: (RecentItem) -> String = { $0.label.text }
    var mark: (RecentItem) -> SessionIdentity? = { _ in nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in // one timeline for the whole list
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in row(item, now: ctx.date) }
            }
        }
    }

    private func row(_ item: RecentItem, now: Date) -> some View {
        let age = WaitingList.age(since: item.at, now: now)
        let repo = label(item)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.white.opacity(0.5)).frame(width: 18)
            if let m = mark(item) { IdentityMark(identity: m, size: 14) }
            Text(repo).font(.caption.bold()).foregroundStyle(.white).lineLimit(1).truncationMode(.middle).help(repo)
            Spacer(minLength: 8)
            Text(age).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            if TerminalJump.available(item.host) { OpenTerminalButton(host: item.host) }
        }
        .padding(.horizontal, 10).frame(minHeight: 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(repo), finished \(age) ago")
    }
}

/// The rest panel (#139): why each row is here, in three sections. Only Needs-you rows have the prominent button;
/// Working and Done rows open their app on a tap. Never shows a reply, prompt, question or command (PDPA #30).
struct PanelSectionsView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let result = model.panelSections(now: ctx.date)
            VStack(alignment: .leading, spacing: 4) {
                if result.isEmpty {
                    Text("Nothing running, nothing waiting.").font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 10)
                }
                ForEach(result.sections, id: \.title) { section in
                    Text(section.title.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5)).tracking(0.6)
                        .padding(.horizontal, 10).padding(.top, 2).accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        PanelRowView(row: row, mark: model.identity(row: row), age: WaitingList.age(since: row.at, now: ctx.date),
                                     review: { if let id = row.pendingId { model.activate(.pending(id)) } },
                                     handled: { row.kind == .terminal ? model.dismissTerminal(row.sessionId) : model.dismissDone(row.sessionId) })
                    }
                }
            }
        }
    }
}

/// One row, the same shape in every section: mark, repo (worktree tag), then "why · branch · app · age".
struct PanelRowView: View {
    let row: PanelSections.Row
    let mark: SessionIdentity
    let age: String
    let review: () -> Void
    /// Clears a terminal ask or an asking reply that was dealt with elsewhere; without it the count would stay up.
    let handled: () -> Void
    @State private var hover = false
    @State private var failure: String?
    @State private var busy = false
    @State private var token = 0

    private var appName: String? {
        guard let pid = row.host?.pid, let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName, !n.isEmpty else { return nil }
        return n
    }
    private var canOpen: Bool { TerminalJump.available(row.host) }
    private var tint: Color {
        switch row.kind {
        case .approval: return .orange
        case .question: return .cyan
        case .terminal, .asksYou: return .purple
        case .working: return .green
        case .finished: return .white.opacity(0.45)
        }
    }
    private var symbol: String {
        switch row.kind {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .terminal: return "terminal.fill"
        case .asksYou: return "text.bubble.fill"
        case .working: return "circle.dotted"
        case .finished: return "checkmark.circle"
        }
    }
    /// "Approve Bash? · main · Orca · 2m": why it is here first, then where it lives.
    private var subtitle: String {
        (failure.map { [$0] } ?? [row.detail] + [row.branch, appName].compactMap { $0 } + [age]).joined(separator: " · ")
    }
    private var spoken: String {
        "\(mark.spoken), \(row.label.repo)\(row.label.worktree.map { ", worktree \($0)" } ?? ""), \(subtitle)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                RepoTitle(repo: row.label.repo, worktree: row.label.worktree, mark: mark)
                Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(failure != nil ? Color.red.opacity(0.9) : (row.kind == .finished ? Color.white.opacity(0.6) : tint.opacity(0.95))).lineLimit(1).truncationMode(.tail).help(subtitle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if row.hasButton { HStack(spacing: 6) { button; handledButton }.fixedSize().layoutPriority(2) }
        }
        .padding(.horizontal, 10).frame(minHeight: row.hasButton ? WaitingList.needsRowHeight : 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover && !row.hasButton && canOpen ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pressFeedback(enabled: !row.hasButton) // a row with its own buttons has no row tap
        .onTapGesture { if !row.hasButton { openApp() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityAction(named: "Open \(appName ?? "terminal")") { if canOpen || row.kind == .approval || row.kind == .question { primary() } }
        .accessibilityActions { if row.hasButton && row.kind != .approval && row.kind != .question { Button("Handled", action: handled) } }
    }

    @ViewBuilder private var handledButton: some View {
        if row.kind == .terminal || row.kind == .asksYou {
            ChipButton(title: "Handled", kind: .quiet, action: handled).accessibilityLabel("Handled, \(row.label.repo)")
                .padding(.leading, 12) // quiet has no leading padding (#213); keep the gap after Jump
        }
    }

    @ViewBuilder private var button: some View {
        switch row.kind {
        case .approval, .question:
            ChipButton(title: row.kind == .question ? "Answer" : "Review", kind: .primary, action: review).accessibilityLabel("\(row.kind == .question ? "Answer" : "Review"), \(row.label.repo)")
        default:
            if canOpen { OpenTerminalButton(host: row.host, kind: .primary).accessibilityLabel("Open \(appName ?? "terminal"), \(row.label.repo)") }
        }
    }

    private func primary() { if row.kind == .approval || row.kind == .question { review() } else { openApp() } }

    /// A tap on a row without a button opens its app; a failure shows in the row for a few seconds instead of doing nothing.
    private func openApp() {
        guard canOpen, !busy else { return }
        busy = true; failure = nil; token += 1
        let mine = token
        TerminalJump.open(row.host) { v in
            busy = false
            guard let text = JumpFeedback.text(for: v, appName: appName ?? "the app") else { return } // landed, or landed unconfirmed
            failure = text.line
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if token == mine { failure = nil } }
        }
    }
}

/// The waiting list (#53, #101): NEEDS YOU on top (act on these), FINISHED below (FYI). NEEDS YOU rows show the repo, a worktree
/// tag, a verb-led label (tool name or question count) and the age, never the question or command (PDPA #30). FINISHED rows add
/// the first line of the reply (60 chars at most, the outcome only, in memory, never logged), or "finished" when there is none.
/// Arrows, Return, Esc and Delete (dismiss a FINISHED row) are handled by the panel.
private struct StaticRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var staticRender: Bool { get { self[StaticRenderKey.self] } set { self[StaticRenderKey.self] = newValue } }
}

struct WaitingListView: View {
    /// True only in the gallery's still renders (ImageRenderer draws a ScrollView blank).
    @Environment(\.staticRender) private var staticRender
    @ObservedObject var model: NotchModel

    private func section(_ title: String, count: Int, clearAll: (() -> Void)? = nil) -> some View {
        HStack {
            Text("\(title) (\(count))").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).tracking(0.6)
            Spacer(minLength: 0)
            if let clearAll {
                Button(action: clearAll) { Text("Clear all").font(.caption2).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 6).frame(minHeight: 24).contentShape(Rectangle()) } // 24pt target; the 22pt header frame keeps its height
                    .buttonStyle(PressStyle()).help("Move every finished thread to Recent").accessibilityLabel("Clear all finished")
            }
        }
        .padding(.horizontal, 10).frame(height: WaitingList.sectionHeaderHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private func needsRows(_ layout: WaitingLayout) -> some View {
        VStack(spacing: 0) {
            ForEach(layout.needs) { item in
                NeedsRow(item: item, mark: model.identity(item: item), selected: model.listSelection == item.target, host: model.terminalItems.first { .terminal($0.sessionId) == item.target }?.host,
                         open: { model.activate(item.target) },
                         handled: { if case .terminal(let sid) = item.target { model.dismissTerminal(sid) } })
                    .frame(height: WaitingList.needsRowHeight).id(item.target)
            }
        }
    }

    private func finishedRows(_ layout: WaitingLayout) -> some View {
        VStack(spacing: 0) {
            ForEach(layout.finished) { item in
                FinishedRow(item: item, mark: model.identity(item: item), selected: model.listSelection == item.target,
                            open: { model.activate(item.target) }, dismiss: { if case .done(let sid) = item.target { model.dismissDone(sid) } })
                    .frame(height: WaitingList.finishedRowHeight).id(item.target)
            }
        }
    }

    /// "+N more" (collapsed) or "Show fewer" (expanded): a real row, reachable by arrows, Return or click.
    private func moreRow(_ layout: WaitingLayout) -> some View {
        let selected = model.listSelection == .moreToggle
        let text = layout.expanded ? "Show fewer" : "+\(layout.hiddenFinished) more"
        return Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(selected ? 0.9 : 0.55))
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: WaitingList.moreRowHeight, maxHeight: WaitingList.moreRowHeight, alignment: .leading)
            .background(rowBackground(selected: selected, hover: false))
            .hitTarget24(drawn: WaitingList.moreRowHeight, below: true) // drawn 18pt (settled row height), 24pt target (C27)
            .pressFeedback().onTapGesture { model.toggleFinished() }
            .accessibilityLabel(layout.expanded ? "Show fewer finished" : "\(layout.hiddenFinished) more finished, show all")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { model.toggleFinished() }
    }

    var body: some View {
        let layout = model.waitingLayout
        VStack(alignment: .leading, spacing: WaitingList.sectionGap) {
            if !layout.needs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    section("NEEDS YOU", count: layout.needs.count)
                    if layout.needsScrolls {
                        ScrollViewReader { proxy in
                            ScrollView { needsRows(layout) }.frame(height: layout.needsHeight)
                                .onChange(of: model.listSelection) { if let t = $0, layout.needs.contains(where: { $0.target == t }) { proxy.scrollTo(t) } }
                        }
                    } else { needsRows(layout) }
                }
            }
            if layout.totalFinished > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    section("FINISHED", count: layout.totalFinished, clearAll: { model.dismissDone(nil) })
                    if layout.expanded, staticRender {
                        finishedRows(layout).frame(height: layout.finishedHeight, alignment: .top).clipped() // gallery only: ImageRenderer draws ScrollView blank
                    } else if layout.expanded {
                        ScrollViewReader { proxy in
                            ScrollView { finishedRows(layout) }.frame(height: layout.finishedHeight)
                                .onChange(of: model.listSelection) { if let t = $0, layout.finished.contains(where: { $0.target == t }) { proxy.scrollTo(t) } }
                        }
                    } else { finishedRows(layout) }
                    if layout.hasToggle { moreRow(layout) }
                }
            }
            Text("↑↓ move · Return open · ⌫ dismiss · Esc close")
                .font(.caption2).foregroundStyle(.white.opacity(0.6)).padding(.leading, 4)
                .frame(height: NotchMetrics.keyHintHeight, alignment: .bottomLeading)
        }
    }
}

/// Per-repo identity (#89): a colour, a shape and the repo's letter, so colour is never the only cue. Decorative: the
/// surrounding row or card carries the spoken name, so it is hidden from VoiceOver.
struct IdentityMark: View {
    let identity: SessionIdentity
    var size: CGFloat = 14
    private static let palette: [Color] = [
        Color(red: 0.34, green: 0.70, blue: 0.95), Color(red: 0.30, green: 0.78, blue: 0.45), Color(red: 0.96, green: 0.85, blue: 0.30), Color(red: 0.95, green: 0.50, blue: 0.70),
        Color(red: 0.66, green: 0.52, blue: 0.95), Color(red: 0.25, green: 0.78, blue: 0.76), Color(red: 0.72, green: 0.88, blue: 0.30), Color(red: 0.40, green: 0.50, blue: 0.95)]
    private struct Tri: Shape {
        func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p }
    }
    @ViewBuilder private var shape: some View {
        let c = Self.palette[identity.colour % Self.palette.count]
        switch identity.shape {
        case .circle: Circle().fill(c)
        case .square: RoundedRectangle(cornerRadius: size * 0.2).fill(c)
        case .diamond: RoundedRectangle(cornerRadius: size * 0.12).fill(c).rotationEffect(.degrees(45)).scaleEffect(0.78)
        case .triangle: Tri().fill(c)
        }
    }
    var body: some View {
        ZStack {
            shape
            Text(identity.glyph).font(.system(size: SessionIdentity.glyphSize(for: size), weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.78))
                .offset(y: identity.shape == .triangle ? size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The identity mark before a header line.
    /// Same view structure with or without a mark (a zero-width placeholder stands in), so a header never re-identifies
    /// when its mark appears; the text keeps layout priority so the mark cannot squeeze it.
    func identityLead(_ mark: SessionIdentity?) -> some View {
        HStack(alignment: .center, spacing: 0) {
            if let mark { IdentityMark(identity: mark, size: 14).padding(.trailing, 6) } else { Color.clear.frame(width: 0, height: 14) }
            self.layoutPriority(1)
        }
    }
}

/// "repo" with the worktree as a small secondary tag (only linked worktrees have one).
struct RepoTitle: View {
    let repo: String
    let worktree: String?
    var mark: SessionIdentity? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let mark { IdentityMark(identity: mark, size: 14) }
            Text(repo).font(.caption.bold()).foregroundStyle(.white).lineLimit(1).truncationMode(.middle).help(repo).layoutPriority(1)
            if let worktree {
                // Content width (#209): 16 Characters from the core helper, and never wider than 110pt (wide glyphs middle-
                // truncate). A short tag no longer claims the cap.
                WidthCap(110) {
                    Text(RepoLabel.worktreeTag(worktree)).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle).help(worktree)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Hugs its content up to `cap` points wide (#209). Unlike `.frame(maxWidth:)`, which is flexible and claims the whole cap in an
/// HStack, this proposes at most `cap` to its child and reports the child's own size, so a short child stays short.
struct WidthCap: Layout {
    let cap: CGFloat
    init(_ cap: CGFloat) { self.cap = cap }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// One line per session (#90): identity mark, repo (worktree tag), and the live word on the right. Read-only: no tap, no focus.
/// `text` is the live word, or the session's real state; `live` dims it when it is only a state. One line at least
/// `GlanceMetrics.rowHeight` tall (minHeight, so larger Dynamic Type grows the row instead of clipping it).
struct GlanceRow: View {
    let label: RepoLabel
    let mark: SessionIdentity
    let text: String
    let live: Bool
    var body: some View {
        HStack(spacing: 6) {
            IdentityMark(identity: mark, size: 12)
            Text(label.repo).font(.caption.bold()).foregroundStyle(.white).lineLimit(1).truncationMode(.middle).help(label.repo).layoutPriority(1)
            if let wt = label.worktree {
                // Content width, 16 Characters and at most 90pt (#209).
                WidthCap(90) { Text(RepoLabel.worktreeTag(wt)).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle).help(wt) }
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 6)
            Text(text).font(.caption2).foregroundStyle(.white.opacity(live ? 0.75 : 0.5)).lineLimit(1)
        }
        .frame(minHeight: GlanceMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.repo), \(label.worktree.map { "worktree \($0), " } ?? "")\(mark.spokenShort), \(text)")
    }
}

private func rowBackground(selected: Bool, hover: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.18 : hover ? 0.1 : 0))
}

/// A row you act on: verb-led label, one primary button (terminal rows add "Handled").
struct NeedsRow: View {
    let item: WaitingItem
    var mark: SessionIdentity? = nil
    let selected: Bool
    let host: HostInfo?
    let open: () -> Void
    let handled: () -> Void
    @State private var hover = false

    private var symbol: String {
        switch item.kind {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .terminal: return "terminal.fill"
        case .done: return "checkmark.circle.fill"
        }
    }
    private var tint: Color { item.kind == .approval ? .orange : item.kind == .question ? .cyan : .purple }

    private var actionTitle: String { item.kind == .question ? "Answer" : "Review" }
    private var subject: String { "\(mark.map { "\($0.spoken), " } ?? "")\(item.repo)\(item.worktree.map { ", worktree \($0)" } ?? "")" }

    /// One 15s timeline per row feeds both the visible age and the VoiceOver label, so they never disagree.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in row(age: WaitingList.age(since: item.at, now: ctx.date)) }
    }

    private func row(age: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                RepoTitle(repo: item.repo, worktree: item.worktree, mark: mark)
                Text("\(item.label) · \(age)").font(.caption2.monospacedDigit()).foregroundStyle(tint.opacity(0.95)).lineLimit(1).truncationMode(.tail).help("\(item.label) · \(age)")
            }
            .layoutPriority(1) // the names give way last-but-one; the buttons keep their size
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if item.kind == .terminal {
                    if TerminalJump.available(host) {
                        OpenTerminalButton(host: host, title: "Jump", kind: .primary).accessibilityLabel("Jump to terminal, \(subject)")
                    }
                    ChipButton(title: "Handled", kind: .quiet, action: handled).accessibilityLabel("Handled, \(subject)")
                        .padding(.leading, 12) // quiet has no leading padding (#213); keep the gap after Jump
                } else {
                    ChipButton(title: actionTitle, kind: .primary, action: open).accessibilityLabel("\(actionTitle), \(subject)")
                }
            }
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .background(rowBackground(selected: selected, hover: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pressFeedback(dimOnly: true) // holds its own buttons: dim, never scale
        .onTapGesture(perform: open)
        .animation(nil, value: selected) // keyboard-driven: instant (#208)
        .animation(Motion.hover, value: hover)
        .accessibilityElement(children: .contain) // the labelled buttons stay reachable inside the row
        .accessibilityLabel("\(subject), \(item.label), \(age)")
        .accessibilityAction(named: item.kind == .terminal ? "Open in list" : actionTitle, open)
    }
}

/// One line, FYI: repo, outcome, age. No buttons; the whole row opens, and an x shows on hover.
struct FinishedRow: View {
    let item: WaitingItem
    var mark: SessionIdentity? = nil
    let selected: Bool
    let open: () -> Void
    let dismiss: () -> Void
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in row(age: WaitingList.age(since: item.at, now: ctx.date)) }
    }

    private func row(age: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.white.opacity(0.45)).frame(width: 18)
            RepoTitle(repo: item.repo, worktree: item.worktree, mark: mark).layoutPriority(1)
            if item.asksYou { Text("asks you").font(.caption2).foregroundStyle(Color.orange).lineLimit(1).fixedSize() }
            // The repo label wins space first, but the snippet (or "finished") keeps a floor so the row never reads as empty.
            Text(item.snippet ?? "finished").font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.tail).help(item.snippet ?? "finished")
                .frame(minWidth: 36, alignment: .leading)
            Spacer(minLength: 6)
            Text(age).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .padding(.horizontal, -2) // 24 x 24 target, same 20pt layout width: the age and snippet do not move
            .buttonStyle(PressStyle()).opacity(hover || selected ? 1 : 0).allowsHitTesting(hover || selected).help("Dismiss (moves to Recent)").accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .background(rowBackground(selected: selected, hover: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pressFeedback(dimOnly: true) // holds its own buttons: dim, never scale
        .onTapGesture(perform: open)
        .animation(nil, value: selected) // keyboard-driven: instant (#208)
        .animation(Motion.hover, value: hover)
        // One button for the row; Dismiss is its own action, not a nested element inside a button.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mark.map { "\($0.spoken), " } ?? "")\(item.repo)\(item.worktree.map { ", worktree \($0)" } ?? ""), \(item.asksYou ? "asks you, " : "")\(item.snippet ?? "finished"), \(age)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}
