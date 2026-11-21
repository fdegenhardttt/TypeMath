import Cocoa

/// The floating card next to the caret: an answer with a Tab hint, or a graph.
final class AnswerPopup {
    private let panel: NSPanel
    private let content = NSStackView()
    private let answerRow: NSStackView
    private let answerLabel = NSTextField(labelWithString: "")
    private let graphView = GraphView()
    private let tabLabel = NSTextField(labelWithString: "⇥")
    /// The graph on screen, for copying.
    private var graph: Evaluator.Graph?
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        answerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        answerLabel.textColor = .labelColor

        tabLabel.font = .systemFont(ofSize: 13, weight: .regular)
        tabLabel.textColor = .tertiaryLabelColor

        answerRow = NSStackView(views: [answerLabel, tabLabel])
        answerRow.orientation = .horizontal
        answerRow.alignment = .firstBaseline
        answerRow.spacing = 10

        content.orientation = .vertical
        content.addArrangedSubview(answerRow)
        content.addArrangedSubview(graphView)
        content.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    func show(_ match: Evaluator.Match, near caret: NSRect) {
        hideTimer?.invalidate()
        tabLabel.isHidden = false
        graph = match.graph
        let isGraph = match.graph != nil
        if let graph = match.graph {
            graphView.plot(graph)
            content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        } else {
            answerLabel.stringValue = match.answer ?? ""
            content.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        }
        answerRow.isHidden = isGraph
        graphView.isHidden = !isGraph

        panel.contentView!.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize

        // Answers sit beside the caret; the taller graph hangs below the line instead of covering it.
        var origin = isGraph
            ? NSPoint(x: caret.maxX + 6, y: caret.minY - size.height - 6)
            : NSPoint(x: caret.maxX + 6, y: caret.midY - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            if isGraph, origin.y < frame.minY + 4 {
                origin.y = caret.maxY + 6  // no room below: show above the line
            }
            origin.y = min(max(origin.y, frame.minY + 4), frame.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }

    /// Copies the graph on screen to the clipboard as an image, then briefly confirms it in place.
    func copyGraph() {
        guard let graph, let image = GraphView.image(of: graph) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])

        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        answerLabel.stringValue = "Copied"
        tabLabel.isHidden = true
        answerRow.isHidden = false
        graphView.isHidden = true
        content.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        panel.contentView!.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                       display: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in self?.hide() }
    }
}

/// A small plot of y = f(x) with axes and range labels.
final class GraphView: NSView {
    private var points: [CGPoint?] = []
    private var xRange = -10.0...10.0
    private var yRange = -10.0...10.0
    /// The curve's own min and max, without the padding, for the labels.
    private var dataRange = -10.0...10.0
    private var isTrigonometric = false

    private static let labelHeight: CGFloat = 16
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 160 + Self.labelHeight) }

    /// A larger, light-mode rendering of a graph on white, for pasting into documents.
    static func image(of graph: Evaluator.Graph) -> NSImage? {
        let padding: CGFloat = 16
        let view = GraphView(frame: NSRect(x: padding, y: padding, width: 520, height: 320 + labelHeight))
        view.plot(graph)
        let canvas = NSView(frame: view.frame.insetBy(dx: -padding, dy: -padding).offsetBy(dx: padding, dy: padding))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        canvas.addSubview(view)
        canvas.appearance = NSAppearance(named: .aqua)

        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let image = NSImage(size: canvas.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    func plot(_ graph: Evaluator.Graph) {
        isTrigonometric = graph.isTrigonometric
        var range = graph.isTrigonometric ? -2 * Double.pi...2 * Double.pi : -10.0...10.0

        func sample(_ range: ClosedRange<Double>) -> [CGPoint?] {
            let count = 400
            return (0...count).map { i in
                let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(count)
                let y = graph.function(x)
                return y.isFinite ? CGPoint(x: x, y: y) : nil
            }
        }
        var samples = sample(range)
        // Functions only defined for x ≥ 0 (ln, sqrt) get the positive side only.
        if !samples.contains(where: { ($0?.x ?? 0) < 0 }) {
            range = 0...range.upperBound
            samples = sample(range)
        }

        let ys = samples.compactMap { $0?.y }.sorted()
        if let first = ys.first, let last = ys.last {
            var low = first, high = last
            // Ignore spikes near asymptotes (1/x, tan x) when they dwarf the rest of the curve.
            let p2 = ys[Int(Double(ys.count - 1) * 0.02)], p98 = ys[Int(Double(ys.count - 1) * 0.98)]
            if high - low > 20 * (p98 - p2) { low = p2; high = p98 }
            if high - low < 1e-9 { low -= 1; high += 1 }
            dataRange = low...high
            let padding = (high - low) * 0.08
            yRange = (low - padding)...(high + padding)
        }
        xRange = range
        points = samples
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 0, y: Self.labelHeight, width: bounds.width, height: bounds.height - Self.labelHeight)
        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: plot.minX + (p.x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * plot.width,
                    y: plot.minY + (p.y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound) * plot.height)
        }

        // Plot area and axes
        NSColor.quaternaryLabelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6).fill()

        let axes = NSBezierPath()
        axes.lineWidth = 1
        if yRange.contains(0) {
            let y = toView(CGPoint(x: 0, y: 0)).y.rounded() + 0.5
            axes.move(to: CGPoint(x: plot.minX, y: y))
            axes.line(to: CGPoint(x: plot.maxX, y: y))
        }
        if xRange.lowerBound < 0, xRange.contains(0) {
            let x = toView(CGPoint(x: 0, y: 0)).x.rounded() + 0.5
            axes.move(to: CGPoint(x: x, y: plot.minY))
            axes.line(to: CGPoint(x: x, y: plot.maxY))
        }
        NSColor.separatorColor.setStroke()
        axes.stroke()

        // Curve, broken at gaps and asymptotes
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6).addClip()
        let curve = NSBezierPath()
        curve.lineWidth = 2
        curve.lineJoinStyle = .round
        curve.lineCapStyle = .round
        var previous: CGPoint?
        for point in points {
            guard let point else { previous = nil; continue }
            let v = toView(point)
            if let previous, abs(v.y - previous.y) < plot.height {
                curve.line(to: v)
            } else {
                curve.move(to: v)
            }
            previous = v
        }
        NSColor.controlAccentColor.setStroke()
        curve.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Range labels: y inside the plot on the left, x below it.
        let inset: CGFloat = 5
        drawLabel(label(dataRange.upperBound), at: CGPoint(x: plot.minX + inset, y: plot.maxY - inset), alignment: .topLeft)
        drawLabel(label(dataRange.lowerBound), at: CGPoint(x: plot.minX + inset, y: plot.minY + inset), alignment: .bottomLeft)
        drawLabel(xLabel(xRange.lowerBound), at: CGPoint(x: plot.minX, y: 0), alignment: .bottomLeft)
        drawLabel(xLabel(xRange.upperBound), at: CGPoint(x: plot.maxX, y: 0), alignment: .bottomRight)
    }

    private enum Alignment { case topLeft, bottomLeft, bottomRight }

    private func drawLabel(_ text: String, at point: CGPoint, alignment: Alignment) {
        let string = NSAttributedString(string: text, attributes: Self.labelAttributes)
        let size = string.size()
        var origin = point
        switch alignment {
        case .topLeft: origin.y -= size.height
        case .bottomLeft: break
        case .bottomRight: origin.x -= size.width
        }
        string.draw(at: origin)
    }

    private func label(_ value: Double) -> String {
        let magnitude = dataRange.upperBound - dataRange.lowerBound
        return Evaluator.format(value, maxFractionDigits: magnitude < 10 ? 2 : 0)
    }

    private func xLabel(_ value: Double) -> String {
        guard isTrigonometric, value != 0 else { return Evaluator.format(value) }
        return value < 0 ? "-2π" : "2π"
    }
}

/// The VBA suggestion list next to the caret: up to four rows, one selected.
final class SuggestionPopup {
    private let panel: NSPanel
    private let list = NSStackView()
    private(set) var suggestions: [VBASuggestion] = []
    private(set) var selected = 0
    private var caret = NSRect.zero

    var isVisible: Bool { panel.isVisible }
    var selectedSuggestion: VBASuggestion? { suggestions.indices.contains(selected) ? suggestions[selected] : nil }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.topAnchor.constraint(equalTo: background.topAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    func show(_ suggestions: [VBASuggestion], near caret: NSRect) {
        guard !suggestions.isEmpty else { return hide() }
        self.suggestions = Array(suggestions.prefix(VBASuggestions.maxCount))
        self.caret = caret
        selected = 0
        render()
    }

    func move(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + offset + suggestions.count) % suggestions.count
        render()
    }

    func hide() {
        suggestions = []
        panel.orderOut(nil)
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, suggestion) in suggestions.enumerated() {
            list.addArrangedSubview(row(for: suggestion, isSelected: index == selected))
        }
        for view in list.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        panel.contentView!.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize

        // Below the line being typed, so the code itself stays visible.
        var origin = NSPoint(x: caret.minX - 12, y: caret.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y < frame.minY + 4 { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            origin.y = min(max(origin.y, frame.minY + 4), frame.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func row(for suggestion: VBASuggestion, isSelected: Bool) -> NSView {
        let label = NSTextField(labelWithString: suggestion.label)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        let content = NSStackView(views: [label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        return content
    }
}

/// The code-check card above the line: the helper's face, what's wrong where, and a remark.
final class IssuePopup {
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let face = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let remark = NSTextField(labelWithString: "")
    private var hideTimer: Timer?
    private var shakeTimer: Timer?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false

        face.font = .systemFont(ofSize: 28)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.preferredMaxLayoutWidth = 320
        title.maximumNumberOfLines = 2
        remark.font = .systemFont(ofSize: 12)
        remark.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, remark])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let content = NSStackView(views: [face, text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(tint)
        background.addSubview(content)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tint.topAnchor.constraint(equalTo: background.topAnchor),
            tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Shows the card above `caret` for four seconds.
    func show(_ reaction: Reaction, near caret: NSRect) {
        face.stringValue = reaction.face
        title.stringValue = reaction.title
        remark.stringValue = reaction.remark ?? ""
        remark.isHidden = reaction.remark == nil
        tint.isHidden = reaction.level < Grumpiness.maxLevel

        panel.contentView!.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        var origin = NSPoint(x: caret.minX - 12, y: caret.maxY + 6)  // above the line; suggestions go below
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y + size.height > frame.maxY - 4 { origin.y = caret.minY - size.height - 6 }
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            origin.y = min(max(origin.y, frame.minY + 4), frame.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if reaction.level >= Grumpiness.maxLevel - 1 { shake(hard: reaction.level == Grumpiness.maxLevel) }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() {
        hideTimer?.invalidate()
        shakeTimer?.invalidate()
        panel.orderOut(nil)
    }

    /// A quick side-to-side wobble: once when annoyed, longer and wider when furious.
    private func shake(hard: Bool) {
        shakeTimer?.invalidate()
        let home = panel.frame.origin
        let offsets: [CGFloat] = hard ? [-9, 9, -8, 8, -6, 6, -3, 3, 0] : [-5, 5, -3, 3, 0]
        var step = 0
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
            guard let self, step < offsets.count else { timer.invalidate(); return }
            self.panel.setFrameOrigin(NSPoint(x: home.x + offsets[step], y: home.y))
            step += 1
        }
    }
}
