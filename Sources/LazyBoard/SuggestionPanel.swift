import Cocoa
import Carbon.HIToolbox

/// A small glass capsule above and to the right of the caret: the correction, a loading indicator, or a check mark.
/// Uses the system Liquid Glass material on macOS 26 and a vibrancy material before that.
final class SuggestionPanel {
    private let panel: NSPanel
    private let content = NSView()
    private let rows = NSStackView()
    private let keys = NSStackView()
    private let stack: NSStackView
    private let dots = LoadingDots()
    private let glowRing = GlowRing()
    private(set) var isLoading = false
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0.01 }
    /// A click on offered fix number `index`.
    var onPick: ((Int) -> Void)?
    /// A click on a key badge: the virtual key code it stands for (Tab, Return, Escape).
    var onKey: ((Int) -> Void)?

    /// Whether a click at this point (global, top-left origin, as event taps report it) lands on the popup.
    func contains(screenPoint p: CGPoint) -> Bool {
        guard isVisible, let primary = NSScreen.screens.first else { return false }
        return panel.frame.contains(NSPoint(x: p.x, y: primary.frame.height - p.y))
    }

    private static let secondaryFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let keyFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    /// Mid gray reads over both light and dark glass.
    private static let highlightColor = NSColor.gray.withAlphaComponent(0.3)
    private static let padding = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 9)

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Clickable, but never key: the text box keeps the focus.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.alphaValue = 0

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keys.orientation = .horizontal
        keys.spacing = 4
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack = NSStackView(views: [rows, keys])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = Self.padding
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.wantsLayer = true
        content.addSubview(stack)
        glowRing.frame = content.bounds
        glowRing.autoresizingMask = [.width, .height]
        content.addSubview(glowRing, positioned: .below, relativeTo: stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = 16
            container = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            effect.addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            container = effect
        }
        panel.contentView = container
    }

    // MARK: Modes

    func show(text: String, near point: NSPoint) {
        show(options: [text], selected: 0, hint: "⇥ fix", near: point)
    }

    /// Candidate corrections; the selected one is what Tab applies next. With `original`, the words that
    /// changed are emphasised; with several options only the part that differs between them is shown.
    func show(options: [String], selected: Int, hint: String, near point: NSPoint, original: String? = nil) {
        stopLoading()
        clearRows()
        let displays = Self.displayStrings(options: options, original: original)
        for (i, option) in options.enumerated() {
            let isSelected = i == selected
            let row = ClickStack()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.onClick = { [weak self] in self?.onPick?(i) }
            if options.count > 1 {
                let marker = NSView()
                marker.wantsLayer = true
                marker.layer?.cornerRadius = 2.5
                marker.layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
                marker.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([marker.widthAnchor.constraint(equalToConstant: 5), marker.heightAnchor.constraint(equalToConstant: 5)])
                row.addArrangedSubview(marker)
            }
            let label = NSTextField(labelWithAttributedString: Self.styled(displays[i], selected: isSelected))
            _ = option
            // A fix to a whole paragraph must be readable before it is accepted.
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 10
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = true
            label.preferredMaxLayoutWidth = 520
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            rows.addArrangedSubview(row)
        }
        setKeys(hint)
        layoutAndPresent(near: point, maxWidth: 560)
    }

    /// A Claude fix, with the words it changes highlighted. As wide as the text, wrapping past `maxWidth` (or the
    /// text box, if narrower); lined up with the box's left edge just above it (below when there is no room above),
    /// or next to the caret when the box cannot be found.
    func showFix(original: String, options: [String], selected: Int, hint: String, field: NSRect?, near point: NSPoint) {
        stopLoading()
        clearRows()
        setKeys(hint)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(field?.origin ?? point) }) ?? NSScreen.main
        var maxWidth = min(Self.maxWidth, max(field?.width ?? Self.maxWidth, 240))
        if let vf = screen?.visibleFrame { maxWidth = min(maxWidth, vf.width - 16) }
        keys.layoutSubtreeIfNeeded()
        let keysWidth = keys.isHidden ? 0 : keys.fittingSize.width + stack.spacing
        let markerWidth: CGFloat = options.count > 1 ? 11 : 0
        let textWidth = maxWidth - Self.padding.left - Self.padding.right - keysWidth - markerWidth
        for (i, option) in options.enumerated() {
            rows.addArrangedSubview(fixRow(pieces: Self.condensed(Self.changedWords(from: original, to: option)),
                                           marker: options.count > 1 ? i == selected : nil, width: textWidth,
                                           onClick: { [weak self] in self?.onPick?(i) }))
        }
        rows.layoutSubtreeIfNeeded()
        let width = min(max(rows.fittingSize.width + Self.padding.left + Self.padding.right + keysWidth, 44), maxWidth)
        // The stack's fitting size leaves out its top and bottom insets once there are several rows.
        let height = max(rows.fittingSize.height + Self.padding.top + Self.padding.bottom, 30)
        var origin = field.map { NSPoint(x: $0.minX, y: $0.maxY + 6) } ?? NSPoint(x: point.x + 4, y: point.y + 4)
        if let vf = screen?.visibleFrame {
            if origin.y + height > vf.maxY { origin.y = (field?.minY ?? point.y - 26) - 6 - height }
            if origin.x + width > vf.maxX { origin.x = vf.maxX - width - 8 }
            if origin.x < vf.minX { origin.x = vf.minX + 8 }
        }
        hideWork?.cancel()
        present(NSRect(origin: origin, size: NSSize(width: width, height: height)))
    }

    private static let maxWidth: CGFloat = 560

    /// One offered fix; `marker` (with several to choose from) says whether it is the one Tab applies.
    private func fixRow(pieces: [Piece], marker selected: Bool?, width: CGFloat, onClick: @escaping () -> Void) -> NSView {
        let row = ClickStack()
        row.onClick = onClick
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        if let selected = selected {
            let marker = NSView()
            marker.wantsLayer = true
            marker.layer?.cornerRadius = 2.5
            marker.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
            marker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([marker.widthAnchor.constraint(equalToConstant: 5), marker.heightAnchor.constraint(equalToConstant: 5)])
            row.addArrangedSubview(marker)
        }
        let label = NSTextField(labelWithAttributedString: Self.styled(pieces, selected: selected ?? true))
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 8
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        return row
    }

    /// Three small dots bouncing one after another: Claude is checking the text.
    /// With `glow`, the glass lights up: Opus is taking a second, closer look.
    func showLoading(near point: NSPoint, hint: String = "", glow: Bool = false) {
        if glow { glowRing.start() } else { glowRing.stop() }
        clearRows()
        rows.addArrangedSubview(dots)
        setKeys(hint)
        isLoading = true
        dots.start()
        layoutAndPresent(near: point, maxWidth: hint.isEmpty ? 80 : 240)
    }

    /// The line was checked and nothing needed fixing.
    func showCheck(near point: NSPoint) {
        stopLoading()
        clearRows()
        let image = NSImageView()
        if let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "ok") {
            image.image = symbol.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        }
        image.contentTintColor = .labelColor
        rows.addArrangedSubview(image)
        setKeys("")
        layoutAndPresent(near: point, maxWidth: 60)
    }

    func hide() {
        stopLoading()
        hideWork?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.panel.alphaValue < 0.01 else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: Text with the changes emphasised

    /// A piece of display text and whether it is the part that matters.
    struct Piece { let text: String; let emphasised: Bool }

    /// Builds what to show for each option.
    static func displayStrings(options: [String], original: String?) -> [[Piece]] {
        if options.count > 1 {
            return differingParts(options)
        }
        guard let option = options.first else { return [] }
        if let original = original {
            return [changedWords(from: original, to: option)]
        }
        return [[Piece(text: option, emphasised: true)]]
    }

    /// For several options: trim the prefix and suffix they share (snapped to word boundaries),
    /// keep a little context, emphasise the rest.
    static func differingParts(_ options: [String]) -> [[Piece]] {
        let arrays = options.map { Array($0.unicodeScalars) }
        guard let shortest = arrays.map(\.count).min(), shortest > 0 else {
            return options.map { [Piece(text: $0, emphasised: true)] }
        }
        var prefix = 0
        while prefix < shortest, arrays.allSatisfy({ $0[prefix] == arrays[0][prefix] }) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, arrays.allSatisfy({ $0[$0.count - 1 - suffix] == arrays[0][arrays[0].count - 1 - suffix] }) { suffix += 1 }
        // Snap to word boundaries so a whole word is shown as different.
        while prefix > 0, arrays[0][prefix - 1] != " " { prefix -= 1 }
        while suffix > 0, arrays[0][arrays[0].count - suffix] != " " { suffix -= 1 }
        let contextKeys = 14
        return arrays.map { a in
            let pre = String(String.UnicodeScalarView(a[0..<prefix]))
            let mid = String(String.UnicodeScalarView(a[prefix..<(a.count - suffix)]))
            let suf = String(String.UnicodeScalarView(a[(a.count - suffix)...]))
            var pieces: [Piece] = []
            if !pre.isEmpty {
                let shown = pre.unicodeScalars.count > contextKeys ? "…" + String(pre.unicodeScalars.suffix(contextKeys)) : pre
                pieces.append(Piece(text: shown, emphasised: false))
            }
            pieces.append(Piece(text: mid.isEmpty ? "(removed)" : mid, emphasised: true))
            if !suf.isEmpty {
                let shown = suf.unicodeScalars.count > contextKeys ? String(suf.unicodeScalars.prefix(contextKeys)) + "…" : suf
                pieces.append(Piece(text: shown, emphasised: false))
            }
            return pieces
        }
    }

    /// Word-level diff: words that are new or changed are emphasised. Thai has no spaces, so the words
    /// come from the system's word breaking, which splits Thai too.
    static func changedWords(from original: String, to fixed: String) -> [Piece] {
        let a = tokens(original)
        let b = tokens(fixed)
        // LCS table
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var keep = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { keep.insert(j); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        var pieces: [Piece] = []
        for (idx, text) in b.enumerated() {
            let emphasised = !keep.contains(idx) && !text.allSatisfy(\.isWhitespace)
            if let last = pieces.last, last.emphasised == emphasised {
                pieces[pieces.count - 1] = Piece(text: last.text + text, emphasised: emphasised)
            } else {
                pieces.append(Piece(text: text, emphasised: emphasised))
            }
        }
        return pieces
    }

    /// The text cut into words and the gaps between them; joined back together they give the text.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var last = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            if last < range.lowerBound { result.append(String(text[last..<range.lowerBound])) }
            result.append(String(text[range]))
            last = range.upperBound
        }
        if last < text.endIndex { result.append(String(text[last...])) }
        return result
    }

    /// In a long message, unchanged stretches shrink to their ends so every change stays in view.
    static func condensed(_ pieces: [Piece], keep: Int = 24) -> [Piece] {
        guard pieces.contains(where: \.emphasised), pieces.reduce(0, { $0 + $1.text.count }) > 200 else { return pieces }
        return pieces.enumerated().map { i, p in
            let chars = Array(p.text)
            guard !p.emphasised, chars.count > keep * 2 + 4 else { return p }
            let head = String(chars.prefix(keep)), tail = String(chars.suffix(keep))
            if i == 0 { return Piece(text: "…" + tail, emphasised: false) }
            if i == pieces.count - 1 { return Piece(text: head + "…", emphasised: false) }
            return Piece(text: head + " … " + tail, emphasised: false)
        }
    }

    static func styled(_ pieces: [Piece], selected: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in pieces {
            let strong = piece.emphasised
            // Glass flips labelColor to suit what is behind it, but not colours derived from it (alpha, blends):
            // those stay dark over a dark window in light mode. So every run is plain labelColor.
            var attrs: [NSAttributedString.Key: Any] = [
                .font: strong ? NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium) : secondaryFont,
                .foregroundColor: NSColor.labelColor,
            ]
            if strong, pieces.count > 1 { attrs[.backgroundColor] = highlightColor }
            result.append(NSAttributedString(string: piece.text, attributes: attrs))
        }
        return result
    }

    // MARK: Internals

    private func stopLoading() {
        dots.stop()
        glowRing.stop()
        isLoading = false
    }

    private func clearRows() {
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    /// Hint segments separated by " · " become small key badges, e.g. "⇥ Tab แก้ · ↩ ส่ง".
    private func setKeys(_ hint: String) {
        for v in keys.arrangedSubviews { keys.removeArrangedSubview(v); v.removeFromSuperview() }
        let parts = hint.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        keys.isHidden = parts.isEmpty
        for part in parts {
            let label = NSTextField(labelWithString: part)
            label.font = Self.keyFont
            label.textColor = .labelColor
            let badge = ClickStack(views: [label])
            badge.edgeInsets = NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
            badge.setHuggingPriority(.required, for: .horizontal)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 5
            badge.layer?.cornerCurve = .continuous
            badge.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.2).cgColor
            badge.layer?.borderWidth = 0.5
            badge.layer?.borderColor = NSColor.gray.withAlphaComponent(0.4).cgColor
            let code = part.hasPrefix("⇥") ? kVK_Tab : part.hasPrefix("↩") ? kVK_Return : part.hasPrefix("esc") ? kVK_Escape : nil
            if let code = code { badge.onClick = { [weak self] in self?.onKey?(code) } }
            keys.addArrangedSubview(badge)
        }
    }

    private func layoutAndPresent(near point: NSPoint, maxWidth: CGFloat) {
        hideWork?.cancel()
        rows.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let width = min(max(fitting.width, 44), maxWidth)
        let height = max(fitting.height, 30)
        var origin = NSPoint(x: point.x + 4, y: point.y + 4)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.x + width > vf.maxX { origin.x = vf.maxX - width - 8 }
            if origin.x < vf.minX { origin.x = vf.minX + 8 }
            if origin.y + height > vf.maxY { origin.y = point.y - 26 - height }
        }
        present(NSRect(origin: origin, size: NSSize(width: width, height: height)))
    }

    private func present(_ frame: NSRect) {
        if panel.isVisible && panel.alphaValue > 0.5 {
            panel.setFrame(frame, display: true)
            return
        }
        panel.alphaValue = 0
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

/// A row or key badge of the popup that takes clicks itself, rather than the label inside it.
/// The panel never becomes key, so the first click has to count.
final class ClickStack: NSStackView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick != nil && frame.contains(point) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick = onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

/// Opus at work: a colour ring slowly turning around the edge of the glass, and a tint breathing inside it.
final class GlowRing: NSView {
    private let tint = CALayer()
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private static let radius: CGFloat = 16
    private static let colors: [NSColor] = [.systemPurple, .systemBlue, .systemTeal, .systemPink]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tint.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.14).cgColor
        tint.cornerRadius = Self.radius
        tint.cornerCurve = .continuous
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 1)
        ring.colors = Self.turn(0)
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = 2.5
        ring.mask = ringMask
        layer?.addSublayer(tint)
        layer?.addSublayer(ring)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The colours shifted round by `step`, closed back to the first so the conic gradient has no seam.
    private static func turn(_ step: Int) -> [CGColor] {
        let shifted = (0..<colors.count).map { colors[($0 + step) % colors.count].cgColor }
        return shifted + [shifted[0]]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        ring.frame = bounds
        ringMask.frame = bounds
        ringMask.path = CGPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), cornerWidth: Self.radius - 1,
                               cornerHeight: Self.radius - 1, transform: nil)
        CATransaction.commit()
    }

    func start() {
        guard isHidden else { return }
        isHidden = false
        needsLayout = true
        let spin = CAKeyframeAnimation(keyPath: "colors")
        spin.values = (0...Self.colors.count).map { Self.turn($0) }
        spin.duration = 2.4
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.35
        breathe.toValue = 1
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        tint.add(breathe, forKey: "breathe")
    }

    func stop() {
        guard !isHidden else { return }
        isHidden = true
        ring.removeAllAnimations()
        tint.removeAllAnimations()
    }
}

/// Minimal typing indicator: three 5pt mid-gray dots (readable over any glass), bouncing in turn.
final class LoadingDots: NSView {
    private var dotLayers: [CALayer] = []
    private let count = 3
    private let size: CGFloat = 5
    private let gap: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * size + CGFloat(count - 1) * gap, height: size + 8)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for i in 0..<count {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * (size + gap), y: 4, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = NSColor.gray.cgColor
            dot.opacity = 0.5
            layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        let now = CACurrentMediaTime()
        for (i, dot) in dotLayers.enumerated() {
            dot.removeAllAnimations()
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, 3, 0]
            bounce.keyTimes = [0, 0.5, 1]
            bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            bounce.duration = 0.5
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.5, 1, 0.5]
            fade.keyTimes = [0, 0.5, 1]
            fade.duration = 0.5
            let group = CAAnimationGroup()
            group.animations = [bounce, fade]
            group.duration = 1.0
            group.repeatCount = .infinity
            group.beginTime = now + Double(i) * 0.15
            dot.add(group, forKey: "bounce")
        }
    }

    func stop() {
        for dot in dotLayers { dot.removeAllAnimations() }
    }
}
