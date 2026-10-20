// indieshelf: a drag-and-drop shelf that lives in the menu bar.
// Shake the cursor while dragging files and the shelf opens. Drop them on it, go wherever you need,
// drag them back out. Files stay on the shelf until you remove them.
// One file, AppKit only. Build with ./build.sh

import AppKit
import ServiceManagement

let log = ProcessInfo.processInfo.environment["INDIESHELF_DEBUG"] != nil

func debug(_ message: String) {
    if log { FileHandle.standardError.write(Data("indieshelf: \(message)\n".utf8)) }
}

// MARK: - Shake detection

/// Watches the mouse in other apps while the left button is held. If something is being dragged
/// (the drag pasteboard changed since mouse-down) and the cursor quickly reverses
/// direction a few times, that's a shake. A press with no drag at all is just a click.
@MainActor
final class ShakeDetector {
    let minTravel: CGFloat = 30     // pixels between reversals
    let reversalsNeeded = 3
    let window: TimeInterval = 0.7  // seconds the reversals must fit in

    var onShake: () -> Void = {}
    var onClick: () -> Void = {}

    private var monitor: Any?
    private var timer: Timer?
    private var dragCountAtMouseDown = 0
    private var lastX: CGFloat = 0
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []

    // Same x as NSEvent.mouseLocation (only y is flipped), but about 200x cheaper to ask for.
    private var cursorX: CGFloat { CGEvent(source: nil)?.location.x ?? lastX }

    func start() {
        // Global mouse monitors don't need Accessibility permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
    }

    private func mouseDown() {
        dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        lastX = cursorX
        direction = 0
        travel = 0
        reversals = []
        timer?.invalidate()
        // Poll instead of listening to drag events: during a file drag the system
        // may not deliver them to us, but the mouse position is always readable.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            stop()
            if NSPasteboard(name: .drag).changeCount == dragCountAtMouseDown { onClick() }
            return
        }
        let x = cursorX
        let dx = x - lastX
        lastX = x
        guard dx != 0 else { return }

        let newDirection: CGFloat = dx > 0 ? 1 : -1
        if newDirection == direction {
            travel += abs(dx)
            return
        }
        if direction != 0 && travel >= minTravel {
            let now = ProcessInfo.processInfo.systemUptime
            reversals = reversals.filter { now - $0 < window } + [now]
            debug("reversal \(reversals.count)")
        }
        direction = newDirection
        travel = abs(dx)

        guard reversals.count >= reversalsNeeded else { return }
        // A drag must have started since mouse-down, and only files belong on a shelf (not links, text, tabs...).
        let drag = NSPasteboard(name: .drag)
        guard drag.changeCount != dragCountAtMouseDown, hasFiles(drag) else {
            debug("shake ignored: not dragging files")
            reversals = []
            return
        }
        debug("shake")
        stop()  // one shake per drag; nothing left to watch
        onShake()
    }
}

// MARK: - What's on the shelf

private let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOnly)
}

func files(in pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL] ?? []
}

/// The list of files, saved as bookmarks so it survives relaunches and follows files
/// that get moved or renamed. Only references are kept: files are never copied or touched.
@MainActor
final class Store {
    struct Item {
        let url: URL
        let bookmark: Data  // kept, because making a bookmark costs 10x more than reading one
    }

    private(set) var items: [Item] = []
    var onChange: () -> Void = {}
    private let key = "items"
    private var offline: [Data] = []  // files on a disk that isn't connected right now: kept, not shown

    init() { reload() }

    /// Re-reads the saved bookmarks: picks up new locations, forgets files that were deleted.
    /// Writes back and redraws only when something actually changed.
    func reload() {
        let saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        let before = items.map(\.url)
        var rewrite = false
        items = []
        offline = []
        for data in saved {
            var stale = false
            let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            if let url, FileManager.default.fileExists(atPath: url.path), !url.path.contains("/.Trash/") {
                // A stale bookmark still found the file (it moved); a fresh one finds it faster next time.
                let fresh = stale ? try? url.bookmarkData() : nil
                rewrite = rewrite || fresh != nil
                items.append(Item(url: url, bookmark: fresh ?? data))
            } else if onMissingDisk(url?.path ?? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path) {
                offline.append(data)
            } else {
                rewrite = true  // deleted: forget it
            }
        }
        if rewrite { persist() }
        if items.map(\.url) != before { onChange() }
    }

    /// After a drag out: if the files were moved, show where they went once Finder is done.
    func reloadSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reload() }
    }

    /// True for a path on an external disk that's unplugged (or a path we can't even read).
    private func onMissingDisk(_ path: String?) -> Bool {
        guard let path else { return true }
        let parts = path.split(separator: "/")
        guard parts.count > 1, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }

    func add(_ new: [URL]) {
        var known = Set(items.map(\.url.standardizedFileURL.path))
        let added = new.compactMap { url -> Item? in
            guard known.insert(url.standardizedFileURL.path).inserted, let bookmark = try? url.bookmarkData() else { return nil }
            return Item(url: url, bookmark: bookmark)
        }
        guard !added.isEmpty else { return }
        items += added
        save()
    }

    func remove(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        for row in rows.reversed() { items.remove(at: row) }
        save()
    }

    func clear() {
        items = []
        offline = []
        save()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.bookmark) + offline, forKey: key)
    }

    private func save() {
        persist()
        onChange()
    }
}

// MARK: - The shelf

/// The top of the shelf: one stacked icon for everything. Drop files on it, or drag it to take them all.
@MainActor
final class AllItemsView: NSView, NSDraggingSource {
    private let store: Store
    private let pile = NSView()
    private let label = NSTextField(labelWithString: "")
    private var mouseDownEvent: NSEvent?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])

        for _ in 0..<3 {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            pile.addSubview(icon)
        }
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [pile, label])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            pile.widthAnchor.constraint(equalToConstant: 48),
            pile.heightAnchor.constraint(equalToConstant: 48),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let items = store.items
        // The last few file icons fanned out like a little pile, or an inbox when empty. Plain image views:
        // drawing file icons into an image of our own made macOS load them at full size (~40 MB).
        let images = items.isEmpty
            ? [NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)]
            : items.suffix(3).map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        let step: CGFloat = 5
        let side = 48 - step * CGFloat(images.count - 1)
        for (i, view) in pile.subviews.enumerated() {
            let icon = view as! NSImageView
            icon.image = i < images.count ? images[i] : nil
            icon.frame = NSRect(x: step * CGFloat(i), y: 48 - side - step * CGFloat(i), width: side, height: side)
        }
        label.stringValue = switch items.count {
        case 0: "Drop files here"
        case 1: "Drag to take \(items[0].url.lastPathComponent)"
        default: "Drag to take all \(items.count) items"
        }
    }

    // Clicks on the icon or label should reach us, so the whole area is one drag handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Drop in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource as? AllItemsView === self { return [] }
        return hasFiles(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store.add(files(in: sender.draggingPasteboard))
        return true
    }

    // Drag out

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, !store.items.isEmpty else { return }
        mouseDownEvent = nil
        let frame = convert(pile.bounds, from: pile)
        let items = store.items.map { item in
            let dragged = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            dragged.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: item.url.path))
            return dragged
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Like a normal Finder drag: move on the same disk, copy elsewhere. The shelf follows moved files.
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.reloadSoon()
    }
}

/// A table that removes the selected rows on Delete and works on the first click.
@MainActor
final class ShelfTable: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete() } else { super.keyDown(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ShelfController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let header: AllItemsView
    private let table = ShelfTable()
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onClose: () -> Void = {}

    init(store: Store) {
        self.store = store
        header = AllItemsView(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask  // the one column always spans the whole list
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open)
        table.onDelete = { [weak self] in self?.remove() }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(open), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Shelf", action: #selector(remove), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let footer = NSStackView()
        footer.addView(NSButton(title: "Clear All", target: self, action: #selector(clearAll)), in: .leading)
        // Open at Login: small and gray, so it's there when you want it and quiet otherwise.
        login.attributedTitle = NSAttributedString(string: "Open at Login", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        login.controlSize = .small
        login.target = self
        login.action = #selector(toggleLogin)
        footer.addView(login, in: .center)
        footer.addView(NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:))), in: .trailing)

        let view = NSView()
        for part in [header, scroll, footer] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
            NSLayoutConstraint.activate([
                part.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                part.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            ])
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 280),
            view.heightAnchor.constraint(equalToConstant: 380),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 88),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        self.view = view
        reload()
    }

    // Read it every time the shelf opens: it can also be changed in System Settings.
    override func viewWillAppear() {
        super.viewWillAppear()
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func reload() {
        guard isViewLoaded else { return }
        header.refresh()
        table.reloadData()
    }

    func focus() {
        view.window?.makeKey()
        view.window?.makeFirstResponder(table)
    }

    override func cancelOperation(_ sender: Any?) { onClose() }

    /// The right-clicked row, or the selection if the right-click was on it.
    private var targetRows: IndexSet {
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return table.selectedRowIndexes
    }

    @objc private func open() {
        targetRows.forEach { NSWorkspace.shared.open(store.items[$0].url) }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targetRows.map { store.items[$0].url })
    }

    @objc private func remove() { store.remove(targetRows) }

    /// The × on a row: removes just that row (cells are reused, so ask the table which row it's in now).
    @objc private func removeRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        if row >= 0 { store.remove([row]) }
    }

    @objc private func toggleLogin() {
        let app = SMAppService.mainApp
        do {
            if login.state == .on { try app.register() } else { try app.unregister() }
        } catch {
            debug("open at login: \(error.localizedDescription)")
        }
        if app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        login.state = app.status == .enabled ? .on : .off
    }

    @objc private func clearAll() {
        store.clear()
        onClose()
    }

    // Rows

    func numberOfRows(in tableView: NSTableView) -> Int { store.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = store.items[row].url
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? makeCell()
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        cell.textField?.stringValue = url.lastPathComponent
        cell.toolTip = url.path
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("cell")
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Shelf")!,
                              target: self, action: #selector(removeRow(_:)))
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Remove from Shelf"
        // The name takes whatever room is left and truncates, so the × always sits at the right edge.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remove.setContentCompressionResistancePriority(.required, for: .horizontal)
        for part in [image, text, remove] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(part)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = image
        cell.textField = text
        return cell
    }

    // Drag out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        store.items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.reloadSoon()
    }

    // Drop in

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== tableView, hasFiles(info.draggingPasteboard) else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        store.add(files(in: info.draggingPasteboard))
        return true
    }
}

// MARK: - Menu bar icon

/// The tray symbol with a small count tag in the corner. A template image, so it follows the menu bar's colors.
func trayIcon(count: Int) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    let symbol = NSImage(systemSymbolName: count == 0 ? "tray" : "tray.full", accessibilityDescription: "indieshelf")!
        .withSymbolConfiguration(config)!
    guard count > 0 else {
        symbol.isTemplate = true
        return symbol
    }

    let text = count > 99 ? "99+" : "\(count)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold)]
    let textSize = text.size(withAttributes: attributes)
    let tag = NSSize(width: max(12, ceil(textSize.width) + 6), height: 12)
    let size = NSSize(width: symbol.size.width + tag.width / 2, height: max(symbol.size.height, 18))

    let image = NSImage(size: size, flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        symbol.draw(in: NSRect(x: 0, y: (size.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
        let tagRect = NSRect(x: size.width - tag.width, y: size.height - tag.height, width: tag.width, height: tag.height)
        // Cut a gap around the tag, fill the tag, then cut the number out of it.
        context.setBlendMode(.destinationOut)
        NSBezierPath(roundedRect: tagRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 7.5, yRadius: 7.5).fill()
        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 6, yRadius: 6).fill()
        context.setBlendMode(.destinationOut)
        text.draw(at: NSPoint(x: tagRect.midX - textSize.width / 2, y: tagRect.midY - textSize.height / 2), withAttributes: attributes)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "indieshelf, \(count) items"
    return image
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store = Store()
    let shake = ShakeDetector()
    let popover = NSPopover()
    lazy var shelf = ShelfController(store: store)
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        shelf.onClose = { [weak self] in self?.popover.performClose(nil) }
        popover.contentViewController = shelf
        // We close it ourselves on a click elsewhere, but not when that press starts a drag: the files
        // may be on their way to the shelf.
        popover.behavior = .applicationDefined
        popover.delegate = self

        store.onChange = { [weak self] in self?.refresh() }
        refresh()

        // NSWindow passes drag-and-drop calls on to its delegate, so this lets the icon itself take drops.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self

        shake.onShake = { [weak self] in self?.show(activate: false) }
        shake.onClick = { [weak self] in self?.popover.performClose(nil) }
        shake.start()
        debug("loaded \(store.items.count) items, icon accepts drops: \(item.button?.window != nil)")
    }

    private func refresh() {
        shelf.reload()
        // Changing the icon re-positions the shelf hanging from it, and if the menu bar has hidden itself
        // (full-screen apps) the shelf lands on the screen's left edge. So the tag waits until it closes.
        if !popover.isShown { updateIcon() }
    }

    private func updateIcon() {
        statusItem?.button?.image = trayIcon(count: store.items.count)
        statusItem?.button?.toolTip = "indieshelf: \(store.items.count) items"
    }

    func popoverWillClose(_ notification: Notification) {
        isOpen = false
        debug("closing")
    }

    func popoverDidClose(_ notification: Notification) {
        guard !isOpen else { return }  // a quick click already reopened it
        anchor.orderOut(nil)
        updateIcon()
    }

    @objc func toggle() {
        if isOpen { popover.performClose(nil) } else { show(activate: true) }
    }

    /// Open as far as the user is concerned: false as soon as closing starts, not when the fade-out ends.
    private var isOpen = false
    private var focusWhenShown = false

    /// Opening by click takes focus (for Delete, Escape). Opening by shake doesn't, so the drag carries on.
    func show(activate: Bool) {
        guard !isOpen, let button = statusItem?.button else { return }
        if popover.isShown {
            // Still fading out from the last close: finish that at once, so a quick click reopens it.
            popover.animates = false
            popover.close()
            popover.animates = true
        }
        isOpen = true
        store.reload()
        focusWhenShown = activate
        // The shelf hangs from a fixed invisible point, never from the menu bar itself: in full-screen apps the
        // menu bar slides away right after a click and would drag the shelf along mid-animation. The point goes
        // under the icon, or at the cursor when the menu bar is hidden (full-screen apps, Mission Control).
        var point = NSEvent.mouseLocation
        if let window = button.window, window.occlusionState.contains(.visible), window.frame.height > 0 {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            point = NSPoint(x: icon.midX, y: icon.minY)
        }
        anchor.setFrameOrigin(point)
        anchor.orderFrontRegardless()
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
    }

    /// Focus only once the shelf is fully open: taking it during the animation makes the animation stutter.
    func popoverDidShow(_ notification: Notification) {
        guard focusWhenShown else { return }
        NSApp.activate()
        shelf.focus()
    }

    /// An invisible one-point window to hang the shelf from.
    private lazy var anchor: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender.draggingPasteboard) ? .copy : []
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store.add(files(in: sender.draggingPasteboard))
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
