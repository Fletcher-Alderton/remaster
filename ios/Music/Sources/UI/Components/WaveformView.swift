import UIKit

final class WaveformView: UIControl {
    var onSeek: ((CGFloat) -> Void)?
    var progress: CGFloat = 0 {
        didSet {
            let clamped = min(max(progress, 0), 1)
            if progress != clamped {
                progress = clamped
                return
            }
            accessibilityValue = "\(Int((progress * 100).rounded())) percent"
            setNeedsDisplay()
        }
    }

    private let bars: [CGFloat] = WaveformView.makeBars()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "Playback position"
        accessibilityValue = "0 percent"
        accessibilityTraits = .adjustable
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), rect.width > 0 else { return }
        let barWidth: CGFloat = 2
        let gap = max(1, (rect.width - CGFloat(bars.count) * barWidth) / CGFloat(max(1, bars.count - 1)))
        let playedCount = Int((CGFloat(bars.count) * progress).rounded(.down))
        let ranges: [(Range<Int>, UIColor)] = [
            (0..<playedCount, DesignSystem.accent),
            (playedCount..<bars.count, DesignSystem.secondaryText)
        ]
        for (range, color) in ranges {
            guard !range.isEmpty else { continue }
            context.setFillColor(color.cgColor)
            for index in range {
                let height = max(5, rect.height * bars[index])
                let x = CGFloat(index) * (barWidth + gap)
                let y = (rect.height - height) / 2
                context.fill(CGRect(x: x, y: y, width: barWidth, height: height))
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updatePosition(for: touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updatePosition(for: touch)
        return true
    }

    override func accessibilityIncrement() {
        progress = min(1, progress + 0.05)
        onSeek?(progress)
    }

    override func accessibilityDecrement() {
        progress = max(0, progress - 0.05)
        onSeek?(progress)
    }

    private func updatePosition(for touch: UITouch) {
        guard bounds.width > 0 else { return }
        progress = min(max(touch.location(in: self).x / bounds.width, 0), 1)
        onSeek?(progress)
    }

    private static func makeBars() -> [CGFloat] {
        var values: [CGFloat] = []
        for index in 0..<84 {
            let a = abs(sin(CGFloat(index + 4) * 1.693))
            let b = abs(cos(CGFloat(index + 9) * 0.437))
            values.append(0.13 + (a * 0.54) + (b * 0.24))
        }
        return values
    }
}
