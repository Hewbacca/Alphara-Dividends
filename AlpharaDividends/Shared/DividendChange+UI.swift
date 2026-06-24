import SwiftUI

/// SwiftUI presentation for `DividendChange`, shared by the in-app row and the widget so
/// both render increases/cuts identically. The model stays UI-agnostic; this is the one
/// place that maps a change to colors and symbols.
extension DividendChange {
    /// Tint for the amount and change indicator: green up, red down, default otherwise.
    var color: Color {
        switch self {
        case .increased: return .green
        case .decreased: return .red
        case .unchanged, .new: return .primary
        }
    }

    /// Tint for the status caption — secondary for unchanged/new so it reads as informational.
    var captionColor: Color {
        switch self {
        case .increased: return .green
        case .decreased: return .red
        case .unchanged, .new: return .secondary
        }
    }

    /// SF Symbol shown before the amount (nil for "new").
    var symbolName: String? {
        switch self {
        case .increased: return "arrow.up"
        case .decreased: return "arrow.down"
        case .unchanged: return "equal"
        case .new: return nil
        }
    }
}

extension DividendEvent {
    /// Status caption next to the ticker — always present, e.g. "Increased from $0.25 (+4.0%)",
    /// "Cut from $0.25 (-20.0%)", "Unchanged", "New".
    var changeCaption: String {
        switch change {
        case .new: return "New"
        case .unchanged: return "Unchanged"
        case .increased, .decreased:
            guard let prev = previousAmount, prev > 0 else {
                return change == .increased ? "Increased" : "Cut"
            }
            let prevStr = CurrencyFormat.string(prev, currency: currency)
            let pct = (cashAmount - prev) / prev * 100
            let sign = pct >= 0 ? "+" : ""
            let pctStr = String(format: "\(sign)%.1f%%", pct)
            let verb = change == .increased ? "Increased" : "Cut"
            return "\(verb) from \(prevStr) (\(pctStr))"
        }
    }
}
