import AppKit
import SwiftUI
import HeadroomCore

public struct MenuBarItemSnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let shortLabel: String       // e.g. "CLD", "CDX", "CUR", "CLD·W", "X"
    public let fullName: String
    public let headroomPercent: Double  // 0...100 remaining
    public let usedPercent: Double      // 0...100 spent
    public let pace: PaceStatus
    public let isAuthExpired: Bool

    public func displayedPercent(mode: MenuBarMetricMode) -> Int {
        switch mode {
        case .remaining:
            return Int(max(0, min(100, headroomPercent)).rounded())
        case .used:
            return Int(max(0, min(100, usedPercent)).rounded())
        }
    }
}

/// Renders pixel-crisp Retina menu bar images (iStat Menus stacked 2-line style, inline, mini bars)
/// so macOS MenuBarExtra renders multi-line telemetry cleanly at exact 22pt height.
@MainActor
public enum MenuBarRenderer {
    public static func render(
        items: [MenuBarItemSnapshot],
        displayMode: MenuBarDisplayMode,
        metricMode: MenuBarMetricMode,
        colorize: Bool,
        privacyMode: Bool,
        forceLightText: Bool = false
    ) -> NSImage {
        if privacyMode {
            return renderPrivacyImage(forceLightText: forceLightText)
        }
        guard !items.isEmpty else {
            return renderFallbackImage(forceLightText: forceLightText)
        }

        switch displayMode {
        case .stackedMetrics:
            return renderStackedColumns(
                items: Array(items.prefix(5)),
                metricMode: metricMode,
                colorize: colorize,
                forceLightText: forceLightText
            )
        case .inlineMetrics:
            return renderInlineStrip(
                items: Array(items.prefix(4)),
                metricMode: metricMode,
                colorize: colorize,
                forceLightText: forceLightText
            )
        case .miniBars:
            return renderMiniBars(
                items: Array(items.prefix(6)),
                metricMode: metricMode,
                colorize: colorize,
                forceLightText: forceLightText
            )
        case .mostUrgent:
            return renderInlineStrip(
                items: Array(items.prefix(1)),
                metricMode: metricMode,
                colorize: colorize,
                forceLightText: forceLightText
            )
        }
    }

    private static func statusNSColor(for item: MenuBarItemSnapshot, colorize: Bool, forceLightText: Bool) -> NSColor {
        guard colorize else {
            return forceLightText ? NSColor.white : NSColor.labelColor
        }
        if item.isAuthExpired || item.headroomPercent <= 15.0 || item.pace == .burningFast {
            return NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.34, alpha: 1.0) // Crisp coral-red
        } else if item.headroomPercent <= 35.0 || item.pace == .onTrack {
            return NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.16, alpha: 1.0) // Crisp amber
        } else {
            return NSColor(calibratedRed: 0.22, green: 0.84, blue: 0.62, alpha: 1.0) // Crisp emerald-cyan
        }
    }

    private static func labelNSColor(colorize: Bool, forceLightText: Bool) -> NSColor {
        if forceLightText {
            return NSColor.white.withAlphaComponent(0.76)
        }
        return colorize
            ? NSColor.labelColor.withAlphaComponent(0.78)
            : NSColor.labelColor
    }

    /// iStat Menus style: 2-line compact stacked columns (`CLD` on top, `64%` below)
    private static func renderStackedColumns(
        items: [MenuBarItemSnapshot],
        metricMode: MenuBarMetricMode,
        colorize: Bool,
        forceLightText: Bool
    ) -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .bold)
        let height: CGFloat = 22.0
        let colGap: CGFloat = 7.0
        let sidePad: CGFloat = 3.0

        var colWidths: [CGFloat] = []
        var topStrings: [NSAttributedString] = []
        var bottomStrings: [NSAttributedString] = []

        for item in items {
            let topAttr = NSAttributedString(string: item.shortLabel, attributes: [
                .font: topFont,
                .foregroundColor: labelNSColor(colorize: colorize, forceLightText: forceLightText)
            ])
            let valueText = item.isAuthExpired ? "AUTH" : "\(item.displayedPercent(mode: metricMode))%"
            let bottomAttr = NSAttributedString(string: valueText, attributes: [
                .font: bottomFont,
                .foregroundColor: statusNSColor(for: item, colorize: colorize, forceLightText: forceLightText)
            ])
            let w = ceil(max(topAttr.size().width, bottomAttr.size().width, 22.0))
            colWidths.append(w)
            topStrings.append(topAttr)
            bottomStrings.append(bottomAttr)
        }

        let totalWidth = sidePad * 2 + colWidths.reduce(0, +) + colGap * CGFloat(max(0, items.count - 1))
        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            var x = sidePad
            for i in items.indices {
                let colW = colWidths[i]
                let topSize = topStrings[i].size()
                let botSize = bottomStrings[i].size()

                // Bottom-up AppKit coordinates: top label near y=11.5, value near y=1.5
                let topX = x + (colW - topSize.width) / 2.0
                let botX = x + (colW - botSize.width) / 2.0
                topStrings[i].draw(at: NSPoint(x: topX, y: 12.0))
                bottomStrings[i].draw(at: NSPoint(x: botX, y: 1.5))

                x += colW + colGap
            }
            return true
        }
        image.isTemplate = !colorize && !forceLightText
        return image
    }

    /// Single-line compact readout (`CDX 99%  CUR 53%`)
    private static func renderInlineStrip(
        items: [MenuBarItemSnapshot],
        metricMode: MenuBarMetricMode,
        colorize: Bool,
        forceLightText: Bool
    ) -> NSImage {
        let codeFont = NSFont.systemFont(ofSize: 11.0, weight: .semibold)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let sepFont = NSFont.systemFont(ofSize: 10.0, weight: .regular)
        let height: CGFloat = 22.0
        let sidePad: CGFloat = 3.0

        let combined = NSMutableAttributedString()
        let baseLabelColor = forceLightText ? NSColor.white.withAlphaComponent(0.85) : NSColor.labelColor.withAlphaComponent(0.85)
        let sepColor = forceLightText ? NSColor.white.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.35)

        for (idx, item) in items.enumerated() {
            if idx > 0 {
                combined.append(NSAttributedString(string: "  ·  ", attributes: [
                    .font: sepFont,
                    .foregroundColor: sepColor
                ]))
            }
            combined.append(NSAttributedString(string: "\(item.shortLabel) ", attributes: [
                .font: codeFont,
                .foregroundColor: baseLabelColor
            ]))
            let val = item.isAuthExpired ? "!" : "\(item.displayedPercent(mode: metricMode))%"
            combined.append(NSAttributedString(string: val, attributes: [
                .font: pctFont,
                .foregroundColor: statusNSColor(for: item, colorize: colorize, forceLightText: forceLightText)
            ]))
        }

        let textSize = combined.size()
        let totalWidth = ceil(textSize.width + sidePad * 2)
        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            let y = (height - textSize.height) / 2.0
            combined.draw(at: NSPoint(x: sidePad, y: y))
            return true
        }
        image.isTemplate = !colorize && !forceLightText
        return image
    }

    /// Vertical micro-bars with top headroom ceiling cap
    private static func renderMiniBars(
        items: [MenuBarItemSnapshot],
        metricMode: MenuBarMetricMode,
        colorize: Bool,
        forceLightText: Bool
    ) -> NSImage {
        let barW: CGFloat = 4.5
        let gap: CGFloat = 3.0
        let padX: CGFloat = 3.0
        let height: CGFloat = 22.0
        let barH: CGFloat = 12.0
        let baseY: CGFloat = 4.0

        let totalWidth = padX * 2 + CGFloat(items.count) * barW + CGFloat(max(0, items.count - 1)) * gap
        let trackColor = forceLightText ? NSColor.white.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.22)
        let capColor = forceLightText ? NSColor.white.withAlphaComponent(0.55) : NSColor.labelColor.withAlphaComponent(0.55)

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            var x = padX
            for item in items {
                // Ceiling cap tick
                capColor.setFill()
                NSBezierPath(rect: NSRect(x: x, y: baseY + barH + 1.5, width: barW, height: 1.0)).fill()

                // Track
                trackColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: barH), xRadius: 1.2, yRadius: 1.2).fill()

                // Fill
                let pct = CGFloat(item.displayedPercent(mode: metricMode)) / 100.0
                let fillH = max(2.0, barH * min(max(pct, 0.08), 1.0))
                statusNSColor(for: item, colorize: colorize, forceLightText: forceLightText).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: fillH), xRadius: 1.2, yRadius: 1.2).fill()

                x += barW + gap
            }
            return true
        }
        image.isTemplate = !colorize && !forceLightText
        return image
    }

    private static func renderPrivacyImage(forceLightText: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let color = forceLightText ? NSColor.white : NSColor.labelColor
        let attr = NSAttributedString(string: "HR", attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let img = NSImage(size: NSSize(width: ceil(size.width + 8), height: 22), flipped: false) { _ in
            attr.draw(at: NSPoint(x: 4, y: (22 - size.height) / 2))
            return true
        }
        img.isTemplate = !forceLightText
        return img
    }

    private static func renderFallbackImage(forceLightText: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let color = forceLightText ? NSColor.white : NSColor.labelColor
        let attr = NSAttributedString(string: "Headroom", attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let img = NSImage(size: NSSize(width: ceil(size.width + 8), height: 22), flipped: false) { _ in
            attr.draw(at: NSPoint(x: 4, y: (22 - size.height) / 2))
            return true
        }
        img.isTemplate = !forceLightText
        return img
    }
}
