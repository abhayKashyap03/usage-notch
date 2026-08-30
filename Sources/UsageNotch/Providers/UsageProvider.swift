import Foundation

/// A source of usage numbers. Implementations are called off the main thread and
/// keep their own incremental state between refreshes.
protocol UsageProvider: AnyObject {
    var id: String { get }
    func fetch(now: Date) -> ProviderUsage
}
