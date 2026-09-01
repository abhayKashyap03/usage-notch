import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Hosting view for the pill: routes clicks and drags in AppKit.
///
/// SwiftUI's gesture recognisers never fire here — the panel does not become key —
/// so mouse handling lives at this level. A press that moves more than a few points
/// is a reposition; anything shorter is a click, dispatched to whichever control
/// reported that rect.
final class NotchHostingView: NSHostingView<NotchRootView> {
    /// Content rect in SwiftUI coordinates (origin top-left), updated on every change.
    var interactiveRect: CGRect = .zero
    /// Controls published by the SwiftUI tree, in the same coordinate space.
    var hitTargets: [HitTarget] = []
    /// Those controls only exist while the panel is open.
    var targetsEnabled = false

    var onDebug: ((String) -> Void)?
    var onPrimaryClick: (() -> Void)?
    var onTargetClick: ((String) -> Void)?
    var onSecondaryClick: ((NSPoint) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint, CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private static let dragThreshold: CGFloat = 4

    private var pressOrigin: NSPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressOrigin else { return }
        let current = NSEvent.mouseLocation
        let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
        if !isDragging {
            guard hypot(delta.x, delta.y) > Self.dragThreshold else { return }
            isDragging = true
            onDragBegan?()
        }
        onDragMoved?(current, delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil; isDragging = false }
        if isDragging {
            onDragEnded?()
            return
        }
        let point = contentPoint(inWindow: event.locationInWindow)
        onDebug?("click at \(point) flipped=\(isFlipped) rect=\(interactiveRect) targets=\(hitTargets.map(\.id))")
        if targetsEnabled, let hit = hitTargets.first(where: { $0.rect.contains(point) }) {
            onTargetClick?(hit.id)
        } else {
            onPrimaryClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondaryClick?(NSEvent.mouseLocation)
    }

    /// Panels that never activate still need to accept the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI reports rects with the origin at the top-left; AppKit hands us
    /// bottom-left window coordinates. Convert once, in one place.
    private func contentPoint(inWindow point: NSPoint) -> CGPoint {
        // NSHostingView is flipped, so converting from window coordinates already
        // yields SwiftUI's top-left origin. Flipping again is a bug that pushed every
        // click to the mirrored half of the panel.
        let local = convert(point, from: nil)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    @MainActor required init(rootView: NotchRootView) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Wires the panel, the SwiftUI tree, the status-bar menu and the refresh loop together.
@MainActor
final class NotchController: NSObject, NSMenuDelegate {
    private let store = UsageStore()
    private let state = NotchState()
    private var panel: NotchPanel!
    private var hosting: NotchHostingView!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var geometry = NotchGeometry.current()

    /// Slack around the content so the drop shadow is not clipped by the window.
    private static let shadowMargin: CGFloat = 36
    /// How close to an edge the cursor must get, while dragging, to snap to it.
    private static let snapBand: CGFloat = 90

    private var monitors: [Any] = []
    private var mouseTimer: Timer?
    private var claimTimer: Timer?
    private var mouseInside = false

    private struct DragOrigin {
        var cursor: NSPoint
        var topOffset: Double
        var sideOffset: Double
    }
    private var drag: DragOrigin?

    func install() {
        buildPanel()
        buildStatusItem()
        installMouseTracking()

        state.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.updateHitRegion(for: mode)
                self?.debugLog("mode=\(mode)")
            }
            .store(in: &bag)

        // A provider appearing or disappearing changes how big the pill needs to be.
        store.$snapshot
            .map(\.visible.count)
            .removeDuplicates()
            .sink { [weak self] _ in self?.positionPanel() }
            .store(in: &bag)

        store.$sessions
            .map { "\($0.count):\($0.first?.project ?? ""):\($0.first?.detail ?? "")" }
            .removeDuplicates()
            .sink { [weak self] summary in
                self?.debugLog("live sessions=\(summary)")
                self?.positionPanel()
            }
            .store(in: &bag)

        store.$workspaces
            .map { rows in rows.map { "\($0.id):\($0.branch):\($0.changedFiles):\($0.ahead):\($0.behind)" }.joined(separator: "|") }
            .removeDuplicates()
            .sink { [weak self] summary in
                self?.debugLog("workspaces=\(summary)")
                self?.positionPanel()
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLayout() }
            .store(in: &bag)

        // Keep our claim fresh so other widgets know we are still here, and drop it
        // when we quit so they can reclaim the space.
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.publishClaim(for: self.panel.frame)
            }
        }
        heartbeat.tolerance = 5
        RunLoop.main.add(heartbeat, forMode: .common)
        claimTimer = heartbeat

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in NotchClaims.withdraw() }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh(spin: false) }
            .store(in: &bag)

        store.claude.account.onUpdate = { [weak self] in self?.refresh(spin: false) }

        // Ask for the real numbers straight away rather than waiting for a poll that
        // a previous version gated behind a success that could never happen.
        if Settings.shared.useAnthropicAccount, !store.claude.account.isBackingOff {
            store.claude.account.probe { [weak self] ok in
                self?.debugLog("startup account probe: \(ok)")
                self?.refresh(spin: false)
            }
        }

        state.placement = currentPlacement()
        state.mode = state.restingMode
        updateHitRegion(for: state.mode)
        store.start()
        debugLog("panel=\(panel.frame) screen=\(geometry.screen.localizedName) notch=\(geometry.anchorRect) hasNotch=\(geometry.hasNotch)")
    }

    /// Set USAGENOTCH_DEBUG=1 to trace placement and interaction on stderr.
    private func debugLog(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["USAGENOTCH_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(("[usage-notch] " + message() + "\n").utf8))
    }

    // MARK: - Panel

    private func buildPanel() {
        panel = NotchPanel(contentRect: windowFrame())
        hosting = NotchHostingView(rootView: makeRootView())
        hosting.onDebug = { [weak self] message in self?.debugLog(message) }
        hosting.onPrimaryClick = { [weak self] in self?.refresh(spin: true) }
        hosting.onTargetClick = { [weak self] id in
            switch id {
            case "work-mode": self?.toggleMiniMode()
            case "settings": self?.showMenuAtPill()
            default: break
            }
        }
        hosting.onSecondaryClick = { [weak self] location in self?.showContextMenu(at: location) }
        hosting.onDragBegan = { [weak self] in self?.dragBegan() }
        hosting.onDragMoved = { [weak self] cursor, delta in self?.dragMoved(cursor: cursor, delta: delta) }
        hosting.onDragEnded = { [weak self] in self?.dragEnded() }
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
        // Transparent until the cursor is actually over the pill — see mouseMoved().
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private func makeRootView() -> NotchRootView {
        NotchRootView(
            store: store,
            state: state,
            onRefresh: { [weak self] in self?.refresh(spin: true) },
            onToggleMini: { [weak self] in self?.toggleMiniMode() },
            onHitTargets: { [weak self] targets in
                self?.hosting?.hitTargets = targets
                self?.debugLog("targets=" + targets.map(\.id).sorted().joined(separator: ","))
            },
            onPanelHeight: { [weak self] height in
                self?.debugLog("panel measured \(height)")
                self?.positionPanel()
            }
        )
    }

    private func layout(providersFloor: Int = 1) -> Layout {
        Layout(placement: currentPlacement(),
               providers: max(store.snapshot.visible.count, providersFloor),
               sessions: store.sessions.count,
               leadProject: store.sessions.first?.project ?? "",
               leadDetail: store.sessions.first?.detail ?? "",
               measuredBody: state.panelBodyHeight,
               trailLabels: store.snapshot.visible.map { provider in
                   provider.headlineFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
               })
    }

    private func currentPlacement() -> Placement {
        Placement.current(notch: geometry.islandSize)
    }

    /// Big enough for the largest state, so the window never resizes mid-animation.
    private func windowSize() -> CGSize {
        let l = layout(providersFloor: 2)
        let expanded = l.size(for: .expanded)
        let pill = l.size(for: .pill)
        return CGSize(width: max(expanded.width, pill.width) + Self.shadowMargin,
                      height: max(expanded.height, pill.height) + Self.shadowMargin)
    }

    /// Base placement plus the user's drag offset, clamped so the pill stays on screen.
    private func windowFrame() -> CGRect {
        let placement = currentPlacement()
        let size = windowSize()
        var frame = geometry.frame(for: size, placement: placement)
        switch placement.edge {
        case .top: frame.origin.x += CGFloat(Settings.shared.topOffset)
        case .left, .right: frame.origin.y += CGFloat(Settings.shared.sideOffset)
        case .island: break   // island mode is pinned to the notch by definition
        }

        // Keep the pill itself (not the padded window) fully on screen. Top and island
        // placements are meant to occupy the menu-bar strip, so they clamp against the
        // full screen; side placements stay clear of the menu bar.
        let content = placement.contentRect(window: size, content: currentContentSize())
        let screen = geometry.screen.frame
        let ceiling = placement.edge.isSide ? geometry.screen.visibleFrame.maxY : screen.maxY
        let minX = screen.minX - content.minX
        let maxX = screen.maxX - content.maxX
        let minY = screen.minY + (size.height - content.maxY)
        let maxY = ceiling - (size.height - content.minY)
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)

        // Step around any other notch widget that already claimed this strip.
        let obstacles = NotchClaims.obstacles(screen: geometry.screen.localizedName)
        if !obstacles.isEmpty {
            let contentScreen = CGRect(x: frame.minX + content.minX,
                                       y: frame.maxY - content.maxY,
                                       width: content.width, height: content.height)
            let resolved = NotchClaims.resolve(rect: contentScreen, edge: placement.edge,
                                               screen: geometry.screen, obstacles: obstacles)
            frame.origin.x += resolved.minX - contentScreen.minX
            frame.origin.y += resolved.minY - contentScreen.minY
        }

        return CGRect(x: frame.origin.x.rounded(), y: frame.origin.y.rounded(),
                      width: size.width, height: size.height)
    }

    private func currentContentSize(for mode: NotchMode? = nil) -> CGSize {
        layout().size(for: mode ?? state.mode)
    }

    private func positionPanel() {
        let frame = windowFrame()
        panel.setFrame(frame, display: true)
        publishClaim(for: frame)
        updateHitRegion(for: state.mode)
        panel.orderFrontRegardless()
    }

    /// Tell other notch widgets which strip of screen this one occupies.
    private func publishClaim(for frame: CGRect) {
        let content = currentPlacement().contentRect(window: frame.size, content: currentContentSize())
        let screenRect = CGRect(x: frame.minX + content.minX,
                                y: frame.maxY - content.maxY,
                                width: content.width, height: content.height)
        NotchClaims.publish(rect: screenRect, screen: geometry.screen.localizedName,
                            edge: Settings.shared.edge)
    }

    private func rebuildLayout() {
        geometry = NotchGeometry.current()
        state.placement = currentPlacement()
        positionPanel()
    }

    /// Clicks only count where the pill is drawn; the rest of the (deliberately
    /// oversized) window is transparent to whatever is underneath.
    private func updateHitRegion(for mode: NotchMode) {
        let content = currentContentSize(for: mode)
        hosting.interactiveRect = currentPlacement().contentRect(window: panel.frame.size, content: content)
        hosting.targetsEnabled = mode == .expanded
    }

    // MARK: - Mouse tracking
    //
    // A window swallows every click inside its frame, whatever its views' hit tests
    // say — view-level hit testing cannot hand a click to another application. So the
    // panel stays mouse-transparent and only opens up while the cursor is genuinely
    // over the pill, which also gives us hover without a tracking area.

    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { event in handler(event); return event } {
            monitors.append(local)
        }
        // Safety net for movement the monitors miss (space switches, warps).
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.mouseMoved() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    /// Screen rect of the drawn pill, in bottom-left coordinates.
    private func contentScreenRect() -> CGRect {
        let window = panel.frame
        let rect = currentPlacement().contentRect(window: window.size, content: currentContentSize())
        return CGRect(x: window.minX + rect.minX,
                      y: window.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func mouseMoved() {
        guard drag == nil else { return }   // keep events while repositioning
        let inside = contentScreenRect().insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        guard inside != mouseInside else { return }
        mouseInside = inside
        panel.ignoresMouseEvents = !inside
        debugLog("mouse \(inside ? "entered" : "left") pill; ignoresMouseEvents=\(!inside)")
        state.hoverChanged(inside)
        if inside { store.refresh() }
    }

    // MARK: - Dragging

    private func dragBegan() {
        drag = DragOrigin(cursor: NSEvent.mouseLocation,
                          topOffset: Settings.shared.topOffset,
                          sideOffset: Settings.shared.sideOffset)
        panel.ignoresMouseEvents = false
    }

    private func dragMoved(cursor: NSPoint, delta: CGPoint) {
        guard var origin = drag else { return }

        // Dragging into an edge band re-attaches the pill to that edge.
        let screen = geometry.screen.frame
        var edge = Settings.shared.edge
        if cursor.y > screen.maxY - Self.snapBand { edge = .top }
        else if cursor.x < screen.minX + Self.snapBand { edge = .left }
        else if cursor.x > screen.maxX - Self.snapBand { edge = .right }

        if edge == .island { edge = .top }
        if edge != Settings.shared.edge {
            Settings.shared.edge = edge
            state.placement = .current
            centreOnCursor(cursor, edge: edge)
            origin = DragOrigin(cursor: cursor,
                                topOffset: Settings.shared.topOffset,
                                sideOffset: Settings.shared.sideOffset)
            drag = origin
            debugLog("drag snapped to \(edge.rawValue)")
        } else {
            switch edge {
            case .top: Settings.shared.topOffset = origin.topOffset + Double(cursor.x - origin.cursor.x)
            case .left, .right: Settings.shared.sideOffset = origin.sideOffset + Double(cursor.y - origin.cursor.y)
            case .island: break
            }
        }
        positionPanel()
    }

    private func dragEnded() {
        drag = nil
        positionPanel()
        mouseMoved()
    }

    /// Places the pill under the cursor along its new edge, so a snap does not make
    /// it jump to the middle of the screen.
    private func centreOnCursor(_ cursor: NSPoint, edge: NotchEdge) {
        Settings.shared.topOffset = 0
        Settings.shared.sideOffset = 0
        let size = windowSize()
        let base = geometry.frame(for: size, placement: currentPlacement())
        let content = currentPlacement().contentRect(window: size, content: currentContentSize())
        switch edge {
        case .top:
            Settings.shared.topOffset = Double(cursor.x - (base.minX + content.midX))
        case .left, .right:
            Settings.shared.sideOffset = Double(cursor.y - (base.maxY - content.midY))
        case .island:
            break
        }
    }

    // MARK: - Actions

    private func refresh(spin: Bool) {
        debugLog("refresh(spin: \(spin))")
        if spin { state.kickRefreshSpin() }
        store.refresh()
        store.refreshActivity(forceWorkspace: true)
    }

    private func toggleMiniMode() {
        Settings.shared.miniMode.toggle()
        debugLog("work mode -> \(Settings.shared.miniMode)")
        state.settleToResting()
    }

    /// Opens the menu next to the pill itself, for when the menu-bar icon is hidden.
    private func showMenuAtPill() {
        let rect = contentScreenRect()
        showContextMenu(at: NSPoint(x: rect.midX, y: rect.minY))
    }

    /// Right-clicking the pill opens the same menu the status item carries.
    private func showContextMenu(at location: NSPoint) {
        guard let menu = statusItem.menu, let view = panel.contentView else { return }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: panel.convertPoint(fromScreen: location), in: view)
    }

    @objc private func menuRefresh() { refresh(spin: true) }
    @objc private func menuToggleMini() { toggleMiniMode() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuResetPosition() {
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuSetEdge(_ sender: NSMenuItem) {
        guard let edge = NotchEdge(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.shared.edge = edge
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuSetAnchor(_ sender: NSMenuItem) {
        guard let anchor = NotchAnchor(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.shared.anchor = anchor
        Settings.shared.topOffset = 0
        rebuildLayout()
    }

    @objc private func menuSetScreen(_ sender: NSMenuItem) {
        Settings.shared.preferredScreen = sender.representedObject as? String
        Settings.shared.resetOffsets()
        rebuildLayout()
    }

    @objc private func menuToggleProvider(_ sender: NSMenuItem) {
        store.revive()
        switch sender.representedObject as? String {
        case "claude": Settings.shared.showClaude.toggle()
        case "codex": Settings.shared.showCodex.toggle()
        default: break
        }
        refresh(spin: false)
    }

    @objc private func menuToggleAgents() {
        Settings.shared.showAgents.toggle()
        store.refreshActivity()
        positionPanel()
    }

    @objc private func menuToggleWorkspaceState() {
        Settings.shared.showWorkspaceState.toggle()
        store.refreshActivity(forceWorkspace: true)
        positionPanel()
    }

    @objc private func menuSetClaudeMetric(_ sender: NSMenuItem) {
        guard let metric = ClaudeMetric(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.shared.claudeMetric = metric
        refresh(spin: false)
    }

    /// Claude does not publish a usable limit locally, but the user can read their
    /// real percentage off Claude and hand it to us once: the ceiling follows from
    /// that and the value of the block we are currently measuring.
    @objc private func menuCalibrate() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Calibrate the 5-hour windows"
        alert.informativeText =
            "Open Claude, read the current 5-hour usage percentage and how long until it "
            + "resets, and put them here. The percentage sets the ceiling; a reset time "
            + "pins that window, which then chains forward every five hours.\n\n"
            + "Codex has its own field because its reported reset comes from your last "
            + "Codex turn and can be hours old. Leave any field blank to leave it alone."

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 112))
        stack.orientation = .vertical
        stack.spacing = 6
        let percentField = NSTextField(); percentField.placeholderString = "Claude: usage %, e.g. 78"
        let resetField = NSTextField(); resetField.placeholderString = "Claude: minutes until reset"
        let weeklyField = NSTextField(); weeklyField.placeholderString = "Claude: weekly %"
        let codexField = NSTextField(); codexField.placeholderString = "Codex: minutes until reset"
        stack.addArrangedSubview(percentField)
        stack.addArrangedSubview(resetField)
        stack.addArrangedSubview(weeklyField)
        stack.addArrangedSubview(codexField)
        for field in [percentField, resetField, weeklyField, codexField] {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        alert.accessoryView = stack

        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func number(_ field: NSTextField) -> Double? {
            Double(field.stringValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%", with: ""))
        }

        if let percent = number(percentField), percent > 1, percent <= 100 {
            let blockValue = Settings.shared.lastBlockValue
            if blockValue > 0 {
                Settings.shared.claudeSessionLimit = blockValue / (percent / 100)
                debugLog("calibrated ceiling: \(blockValue) is \(percent)%")
            }
        }
        if let minutes = number(resetField), minutes > 0, minutes <= 300 {
            Settings.shared.claudeWindowAnchor = Date().addingTimeInterval(minutes * 60)
            debugLog("calibrated Claude window end: in \(minutes)m")
        }
        if let weekly = number(weeklyField), weekly > 1, weekly <= 100 {
            let weekValue = Settings.shared.lastWeekValue
            if weekValue > 0 {
                Settings.shared.claudeWeeklyLimit = weekValue / (weekly / 100)
                debugLog("calibrated weekly ceiling: \(weekValue) is \(weekly)%")
            }
        }
        if let minutes = number(codexField), minutes > 0, minutes <= 300 {
            Settings.shared.codexWindowAnchor = Date().addingTimeInterval(minutes * 60)
            debugLog("calibrated Codex window end: in \(minutes)m")
        }
        refresh(spin: true)
    }

    @objc private func menuClearCalibration() {
        Settings.shared.claudeSessionLimit = 0
        Settings.shared.claudeWeeklyLimit = 0
        Settings.shared.claudeWindowAnchor = nil
        Settings.shared.codexWindowAnchor = nil
        refresh(spin: false)
    }

    @objc private func menuToggleAutoRefresh() {
        Settings.shared.autoRefreshTokens.toggle()
    }

    @objc private func menuToggleAccount() {
        let enabling = !Settings.shared.useAnthropicAccount
        Settings.shared.useAnthropicAccount = enabling
        store.revive()

        guard enabling else {
            store.claude.account.reset()
            refresh(spin: false)
            return
        }

        guard explainKeychainUse() else {
            Settings.shared.useAnthropicAccount = false
            return
        }
        // Probe once, in the foreground, so the keychain prompt is visible and a
        // refusal turns the setting back off instead of silently doing nothing.
        store.claude.account.probe { [weak self] ok in
            if !ok {
                Settings.shared.useAnthropicAccount = false
                let alert = NSAlert()
                alert.messageText = "Could not read your Claude usage"
                alert.informativeText = """
                Keychain access was denied, the stored token has expired, or Anthropic \
                did not return usage data. Usage Notch will keep using the local estimate.
                """
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            self?.refresh(spin: false)
        }
    }

    @objc private func menuToggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    @discardableResult
    private func explainKeychainUse() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Use your Claude account limits?"
        alert.informativeText = """
        Usage Notch will read the Claude Code OAuth token from your login keychain \
        and call Anthropic's usage endpoint so the 5-hour and weekly rings show real \
        plan utilisation instead of a local estimate.

        macOS will ask you to allow keychain access the first time. The token stays on \
        this Mac, is never written to disk by this app, and is only sent to api.anthropic.com.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                           accessibilityDescription: "Usage Notch")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        for provider in store.snapshot.providers {
            let title: String
            switch provider.status {
            case .missing: title = "\(provider.name): not installed"
            case .failed(let why): title = "\(provider.name): \(why)"
            default:
                let five = provider.session.percent.map { "\($0)%" } ?? "–"
                let week = provider.week.percent.map { "\($0)%" } ?? "–"
                title = "\(provider.name): \(five) · 5h   \(week) · \(provider.week.label)"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(item("Refresh now", #selector(menuRefresh), key: "r"))
        menu.addItem(item(s.miniMode ? "Leave work mode" : "Work mode (hide pill)", #selector(menuToggleMini), key: "h"))

        let displays = NSMenu()
        let auto = item("Automatic (notched screen)", #selector(menuSetScreen(_:)))
        auto.representedObject = nil
        auto.state = s.preferredScreen == nil ? .on : .off
        displays.addItem(auto)
        displays.addItem(.separator())
        for screen in NSScreen.screens {
            let name = screen.localizedName
            let suffix = screen.safeAreaInsets.top > 0 ? " (notch)" : ""
            let mi = item(name + suffix, #selector(menuSetScreen(_:)))
            mi.representedObject = name
            mi.state = s.preferredScreen == name ? .on : .off
            displays.addItem(mi)
        }
        menu.addItem(submenu("Display", displays))

        let edges = NSMenu()
        for edge in NotchEdge.allCases {
            let mi = item(edge.title, #selector(menuSetEdge(_:)))
            mi.representedObject = edge.rawValue
            mi.state = s.edge == edge ? .on : .off
            edges.addItem(mi)
        }
        menu.addItem(submenu("Attach to", edges))

        let position = NSMenu()
        for anchor in NotchAnchor.allCases {
            let mi = item(anchor.title(hasNotch: geometry.hasNotch), #selector(menuSetAnchor(_:)))
            mi.representedObject = anchor.rawValue
            mi.state = s.anchor == anchor ? .on : .off
            mi.isEnabled = s.edge == .top
            position.addItem(mi)
        }
        position.addItem(.separator())
        position.addItem(item("Reset to default spot", #selector(menuResetPosition)))
        menu.addItem(submenu(s.edge == .top ? "Position" : "Position (drag to move)", position))

        let sources = NSMenu()
        let claude = item("Claude Code", #selector(menuToggleProvider(_:)))
        claude.representedObject = "claude"
        claude.state = s.showClaude ? .on : .off
        sources.addItem(claude)
        let codex = item("Codex", #selector(menuToggleProvider(_:)))
        codex.representedObject = "codex"
        codex.state = s.showCodex ? .on : .off
        sources.addItem(codex)
        sources.addItem(.separator())
        let agents = item("Live agent sessions", #selector(menuToggleAgents))
        agents.state = s.showAgents ? .on : .off
        sources.addItem(agents)
        let workspaces = item("Workspace Git state", #selector(menuToggleWorkspaceState))
        workspaces.state = s.showWorkspaceState ? .on : .off
        workspaces.isEnabled = s.showAgents
        sources.addItem(workspaces)
        sources.addItem(.separator())
        for metric in ClaudeMetric.allCases {
            let mi = item("Claude ring: \(metric.title)", #selector(menuSetClaudeMetric(_:)))
            mi.representedObject = metric.rawValue
            mi.state = s.claudeMetric == metric ? .on : .off
            sources.addItem(mi)
        }
        sources.addItem(.separator())
        sources.addItem(item("Calibrate 5-hour limit…", #selector(menuCalibrate)))
        if s.claudeSessionLimit > 0 || s.claudeWeeklyLimit > 0
            || s.claudeWindowAnchor != nil || s.codexWindowAnchor != nil {
            sources.addItem(item("Clear calibration", #selector(menuClearCalibration)))
        }
        sources.addItem(.separator())
        let autoRefresh = item("Keep tokens fresh automatically", #selector(menuToggleAutoRefresh))
        autoRefresh.state = s.autoRefreshTokens ? .on : .off
        sources.addItem(autoRefresh)
        let account = item("Use Claude account limits (keychain)", #selector(menuToggleAccount))
        account.state = s.useAnthropicAccount ? .on : .off
        sources.addItem(account)
        menu.addItem(submenu("Sources", sources))

        let login = item("Open at login", #selector(menuToggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Usage Notch", #selector(menuQuit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }
}
