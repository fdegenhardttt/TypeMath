import Cocoa

/// The floating card next to the caret: an answer with a Tab hint, or a graph.
final class AnswerPopup {
    private let panel: NSPanel
    private let content = NSStackView()
    private let answerRow: NSStackView
    private let answerLabel = NSTextField(labelWithString: "")
    private let graphView = GraphView()

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

        let tabLabel = NSTextField(labelWithString: "⇥")
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
        panel.orderOut(nil)
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
