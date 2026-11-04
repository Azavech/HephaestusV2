// OWNER: ui-tickets — the image viewer window's content (docs/tickets.md › Image viewer).
import AppKit
import HephaestusCore
import SwiftUI

/// The content of an image viewer window: a stored image of a project, or the Feedback sheet's screenshot (`AppModel.feedbackPreviews`).
struct ImageViewerWindow: View {
    let value: ImageViewerValue
    @Environment(AppModel.self) private var app

    @State private var model = ImageViewerModel()
    /// The stored image shown, after Previous and Next.
    @State private var currentPath: String?
    @State private var nsWindow: NSWindow?
    @State private var phase = LoadPhase.loading
    @State private var didResize = false
    /// Items of a chat whose transcript no view of the workspace holds, read with `chats.get`.
    @State private var fetchedChatItems: [ChatItem]?
    @State private var sawSource = false

    enum LoadPhase {
        case loading
        case loaded(NSImage, Data)
        case failed(Data?)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            switch phase {
            case .loading:
                ProgressView()
            case .loaded(let image, _):
                ZoomableImageView(image: image, model: model)
            case .failed(let data):
                VStack(spacing: 12) {
                    Text("The image cannot be displayed.")
                        .foregroundStyle(.secondary)
                    Button("Open With Default App") { openWithDefaultApp(data) }
                        .disabled(data == nil)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle(title)
        .toolbar { toolbar }
        .background(WindowAccessor { window in
            if nsWindow !== window {
                nsWindow = window
            }
        })
        .task(id: loadKey) {
            await load()
        }
        .task(id: chatIDForFetch) {
            await fetchChatItemsIfNeeded()
        }
        .onChange(of: sourceRemoved) { _, removed in
            if removed {
                nsWindow?.close()
            }
        }
        .onAppear {
            model.previous = { step(-1) }
            model.next = { step(1) }
            model.saveAs = { saveAs() }
            model.close = { nsWindow?.performClose(nil) }
            if currentPath == nil, case .stored(_, _, let path) = value {
                currentPath = path
            }
            if case .stored(let deviceID, let projectID, _) = value {
                app.workspace(for: deviceID)?.ensureProjectLoaded(projectID)
            }
        }
    }

    // MARK: Source

    private var workspace: DeviceWorkspace? {
        guard case .stored(let deviceID, _, _) = value else { return nil }
        return app.workspaces[deviceID]
    }

    private var projectID: String? {
        guard case .stored(_, let projectID, _) = value else { return nil }
        return projectID
    }

    private var path: String? {
        guard case .stored(_, _, let path) = value else { return nil }
        return currentPath ?? path
    }

    /// `attachments/<TICKET-ID>/…` or `chats/<CHAT-ID>/…`.
    private var pathOwner: (kind: String, id: String)? {
        guard let path else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private var ticket: Ticket? {
        guard let owner = pathOwner, owner.kind == "attachments", let projectID else { return nil }
        return workspace?.tickets[projectID]?[owner.id]
    }

    private var chatID: String? {
        guard let owner = pathOwner, owner.kind == "chats" else { return nil }
        return owner.id
    }

    private var chatIDForFetch: String? {
        chatID.flatMap { workspace?.transcripts[$0] == nil ? $0 : nil }
    }

    /// The images to step through: for a ticket, its image attachments in order, then those of
    /// each comment in comment order; for a chat, the images of its items in transcript order.
    private var images: [Attachment] {
        if let ticket {
            let all = ticket.attachments + ticket.comments.flatMap(\.attachments)
            return all.filter { AttachmentKinds.isImage(contentType: $0.contentType) }
        }
        if let chatID {
            let items = workspace?.transcripts[chatID]?.items ?? fetchedChatItems ?? []
            return items.flatMap { item -> [Attachment] in
                switch item {
                case .user(let user): return user.attachments
                case .toolResult(let result): return result.images
                case .images(let shown): return shown.images
                default: return []
                }
            }
            .filter { AttachmentKinds.isImage(contentType: $0.contentType) }
        }
        return []
    }

    private var currentIndex: Int? {
        images.firstIndex { $0.path == path }
    }

    private var currentAttachment: Attachment? {
        currentIndex.map { images[$0] }
    }

    /// The file name: the attachment's name, else the stored name without its `<UUID>-` prefix.
    private var name: String {
        if let currentAttachment {
            return currentAttachment.name
        }
        guard let fileName = path?.split(separator: "/").last.map(String.init) else { return "" }
        if fileName.count > 37, Identifiers.isUUID(String(fileName.prefix(36))), fileName.dropFirst(36).first == "-" {
            return String(fileName.dropFirst(37))
        }
        return fileName
    }

    /// `<name> — <TICKET-ID>`, `<name> — <chat title>` or `Feedback Screenshot`.
    private var title: String {
        switch value {
        case .feedbackPreview:
            return "Feedback Screenshot"
        case .stored:
            if let owner = pathOwner, owner.kind == "attachments" {
                return "\(name) — \(owner.id)"
            }
            if let chatID {
                let chatTitle = workspace?.chats[chatID]?.title ?? ""
                return chatTitle.isEmpty ? name : "\(name) — \(chatTitle)"
            }
            return name
        }
    }

    /// True once the source of the window is gone: its attachment, comment or ticket; its chat;
    /// the feedback screenshot when its sheet closes.
    private var sourceRemoved: Bool {
        switch value {
        case .feedbackPreview(let previewID):
            return app.feedbackPreviews[previewID] == nil
        case .stored(_, let projectID, _):
            guard let workspace, let owner = pathOwner else { return false }
            if owner.kind == "attachments" {
                guard let tickets = workspace.tickets[projectID] else { return false }
                guard let ticket = tickets[owner.id] else { return sawSource }
                let paths = ticket.attachments.map(\.path) + ticket.comments.flatMap { $0.attachments.map(\.path) }
                return sawSource && !paths.contains(path ?? "")
            }
            return sawSource && workspace.hasSnapshot && workspace.chats[owner.id] == nil
        }
    }

    private var loadKey: String {
        switch value {
        case .feedbackPreview(let previewID):
            return previewID.uuidString
        case .stored:
            return path ?? ""
        }
    }

    // MARK: Loading

    private func load() async {
        let data: Data?
        switch value {
        case .feedbackPreview(let previewID):
            data = app.feedbackPreviews[previewID]
        case .stored(_, let projectID, _):
            guard let workspace, let path else { return }
            data = try? await AttachmentStore.shared.data(path: path, projectID: projectID, workspace: workspace)
        }
        markSourceSeen()
        guard let data, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            phase = .failed(data)
            return
        }
        phase = .loaded(image, data)
        model.isFitted = true
        resizeOnce(for: image)
    }

    private func markSourceSeen() {
        switch value {
        case .feedbackPreview:
            sawSource = true
        case .stored:
            if ticket != nil || (chatID.flatMap { workspace?.chats[$0] } != nil) {
                sawSource = true
            }
        }
    }

    private func fetchChatItemsIfNeeded() async {
        guard let chatID = chatIDForFetch, let workspace, let uuid = UUID(uuidString: chatID) else { return }
        if let transcript = try? await workspace.call(ChatsGet.self, ChatsGet.Params(chatID: uuid)) {
            fetchedChatItems = transcript.items
            sawSource = true
        }
    }

    /// Once the image is decoded the window resizes once, keeping its top-left corner: to the
    /// image's size when it fits in 80 % of the visible frame of its screen, otherwise to the
    /// largest size with the image's proportions that fits, never smaller than 400 × 300 pt.
    private func resizeOnce(for image: NSImage) {
        guard !didResize, let window = nsWindow else { return }
        didResize = true
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let limit = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        var size = image.size
        if size.width > limit.width || size.height > limit.height {
            let scale = min(limit.width / size.width, limit.height / size.height)
            size = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        }
        size = CGSize(width: max(400, size.width), height: max(300, size.height))
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        window.setFrame(frame, display: true)
        DispatchQueue.main.async {
            model.fit()
            model.focus()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                step(-1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .help("Previous")
            .disabled(!canStep(-1))
            Button {
                step(1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .help("Next")
            .disabled(!canStep(1))
        }
        ToolbarItemGroup(placement: .automatic) {
            if let index = currentIndex, images.count > 0 {
                Text("\(index + 1) of \(images.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if loadedData != nil {
                Text("\(Int((model.zoom * 100).rounded())) %")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 48)
            }
            Button {
                model.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom Out")
            .disabled(loadedData == nil)
            Button {
                model.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom In")
            .disabled(loadedData == nil)
            Button {
                model.actualSize()
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .help("Actual Size")
            .disabled(loadedData == nil)
            Button {
                model.fit()
            } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit")
            .disabled(loadedData == nil)
            Button {
                saveAs()
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .help("Save As…")
            .disabled(loadedData == nil)
        }
    }

    // MARK: Actions

    private var loadedData: Data? {
        if case .loaded(_, let data) = phase { return data }
        return nil
    }

    /// Previous and next go through the images in order, without wrapping around.
    private func canStep(_ delta: Int) -> Bool {
        guard let index = currentIndex else { return false }
        let target = index + delta
        return target >= 0 && target < images.count
    }

    private func step(_ delta: Int) {
        guard canStep(delta), let index = currentIndex else { return }
        phase = .loading
        currentPath = images[index + delta].path
    }

    private func saveAs() {
        guard let data = loadedData else { return }
        let fileName = value.isFeedback ? "Feedback Screenshot.png" : name
        let window = nsWindow
        Task {
            await AttachmentFiles.saveAs(name: fileName, data: data, window: window)
        }
    }

    private func openWithDefaultApp(_ data: Data?) {
        guard let data else { return }
        let id: String
        switch value {
        case .feedbackPreview(let previewID):
            id = previewID.uuidString
        case .stored:
            id = currentAttachment?.id.uuidString ?? path?.split(separator: "/").last.map { String($0.prefix(36)) } ?? UUID().uuidString
        }
        let fileName = value.isFeedback ? "Feedback Screenshot.png" : name
        if let url = try? AttachmentFiles.temporaryCopy(id: id, name: fileName, data: data) {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension ImageViewerValue {
    var isFeedback: Bool {
        if case .feedbackPreview = self { return true }
        return false
    }
}

// MARK: - Model

/// The zoom of a viewer and the actions its keys and toolbar call. Zoom ranges from 10 % to
/// 800 %; each step multiplies or divides it by 1.25.
@MainActor @Observable
final class ImageViewerModel {
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 8
    static let step: CGFloat = 1.25

    var zoom: CGFloat = 1
    /// True while the image is fitted to the window.
    var isFitted = true
    @ObservationIgnored weak var scrollView: ImageScrollView?
    @ObservationIgnored var previous: () -> Void = {}
    @ObservationIgnored var next: () -> Void = {}
    @ObservationIgnored var saveAs: () -> Void = {}
    @ObservationIgnored var close: () -> Void = {}

    func zoomIn() {
        setZoom(zoom * Self.step)
    }

    func zoomOut() {
        setZoom(zoom / Self.step)
    }

    func actualSize() {
        setZoom(1)
    }

    /// Fits the image in the window, never above 100 %.
    func fit() {
        guard let scrollView, let size = scrollView.imageSize, size.width > 0, size.height > 0 else { return }
        let visible = scrollView.contentSize
        let scale = min(1, visible.width / size.width, visible.height / size.height)
        scrollView.setZoom(max(Self.minZoom, scale))
        zoom = scrollView.magnification
        isFitted = true
    }

    /// Double-click: actual size while fitted, fit otherwise.
    func toggleFit() {
        if isFitted {
            actualSize()
        } else {
            fit()
        }
    }

    func focus() {
        scrollView?.focusImage()
    }

    private func setZoom(_ value: CGFloat) {
        guard let scrollView else { return }
        scrollView.setZoom(min(Self.maxZoom, max(Self.minZoom, value)))
        zoom = scrollView.magnification
        isFitted = false
    }

    /// A pinch ended: the zoom is the scroll view's magnification.
    func magnificationChanged(_ value: CGFloat) {
        zoom = value
        isFitted = false
    }
}

// MARK: - AppKit view

/// The image in a magnifying scroll view: pinch and the toolbar zoom, scroll and drag pan, the
/// keys of docs/tickets.md › Image viewer go to the model, Copy copies the image. Animated GIFs
/// play.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let model: ImageViewerModel

    func makeNSView(context: Context) -> ImageScrollView {
        let scrollView = ImageScrollView(model: model)
        scrollView.show(image)
        model.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: ImageScrollView, context: Context) {
        if scrollView.image !== image {
            scrollView.show(image)
            DispatchQueue.main.async {
                model.fit()
                model.focus()
            }
        }
        model.scrollView = scrollView
    }
}

/// The scroll view of the viewer.
final class ImageScrollView: NSScrollView {
    private weak var model: ImageViewerModel?
    private let imageView = ViewerImageView()
    private(set) var image: NSImage?

    init(model: ImageViewerModel) {
        self.model = model
        super.init(frame: .zero)
        contentView = CenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        allowsMagnification = true
        minMagnification = ImageViewerModel.minZoom
        maxMagnification = ImageViewerModel.maxZoom
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        imageView.owner = model
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded(_:)),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var imageSize: CGSize? {
        image?.size
    }

    func show(_ image: NSImage) {
        self.image = image
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
    }

    func setZoom(_ value: CGFloat) {
        let visible = documentVisibleRect
        setMagnification(value, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }

    func focusImage() {
        window?.makeFirstResponder(imageView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let model, model.isFitted {
            DispatchQueue.main.async { [weak model] in
                model?.fit()
            }
        }
    }

    @objc private func liveMagnifyEnded(_ notification: Notification) {
        model?.magnificationChanged(magnification)
    }
}

/// Keeps a document smaller than the view in its centre.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width {
            rect.origin.x = (size.width - rect.width) / 2
        }
        if rect.height > size.height {
            rect.origin.y = (size.height - rect.height) / 2
        }
        return rect
    }
}

/// The image view: first responder of the viewer for its keys and Copy; dragging pans.
final class ViewerImageView: NSImageView {
    weak var owner: ImageViewerModel?
    private var dragStart: NSPoint?
    private var originAtDragStart: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            owner?.toggleFit()
            return
        }
        dragStart = event.locationInWindow
        originAtDragStart = enclosingScrollView?.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = originAtDragStart, let scrollView = enclosingScrollView else { return }
        let scale = scrollView.magnification
        let dx = (event.locationInWindow.x - start.x) / scale
        let dy = (event.locationInWindow.y - start.y) / scale
        let clip = scrollView.contentView
        let flipped = clip.isFlipped ? 1.0 : -1.0
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: origin.x - dx, y: origin.y + dy * flipped),
                                                        size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        originAtDragStart = nil
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch event.keyCode {
        case 123 where flags.isEmpty:
            owner?.previous()
        case 124 where flags.isEmpty:
            owner?.next()
        case 53:
            owner?.close()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let owner else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == .command || flags == [.command, .shift] {
            switch key {
            case "=", "+":
                owner.zoomIn()
                return true
            case "-":
                owner.zoomOut()
                return true
            case "0" where flags == .command:
                owner.actualSize()
                return true
            case "9" where flags == .command:
                owner.fit()
                return true
            case "s", "S":
                if flags == [.command, .shift] {
                    owner.saveAs()
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return image != nil
        }
        return super.validateMenuItem(menuItem)
    }
}
