import Foundation

/// Published Anthropic list prices, USD per million tokens.
/// Cache writes bill at 1.25x input, cache reads at 0.1x input.
struct ModelRate {
    let input: Double
    let output: Double
    var cacheWrite: Double { input * 1.25 }
    var cacheRead: Double { input * 0.1 }
}

enum Pricing {
    private static let table: [(match: String, rate: ModelRate)] = [
        ("opus",   ModelRate(input: 15.0, output: 75.0)),
        ("sonnet", ModelRate(input: 3.0,  output: 15.0)),
        ("haiku",  ModelRate(input: 0.80, output: 4.0)),
        ("fable",  ModelRate(input: 3.0,  output: 15.0)),
    ]

    /// Unknown models fall back to Sonnet-class pricing; cost is always labelled an estimate.
    static func rate(for model: String) -> ModelRate {
        let m = model.lowercased()
        for entry in table where m.contains(entry.match) { return entry.rate }
        return ModelRate(input: 3.0, output: 15.0)
    }

    static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let r = rate(for: model)
        return Double(input) / 1e6 * r.input
            + Double(output) / 1e6 * r.output
            + Double(cacheWrite) / 1e6 * r.cacheWrite
            + Double(cacheRead) / 1e6 * r.cacheRead
    }
}
