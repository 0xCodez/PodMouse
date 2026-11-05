import Foundation

private let prefersRussian = Locale.preferredLanguages.contains { $0.hasPrefix("ru") }

/// The app ships in English and Russian.
func L(_ english: String, _ russian: String) -> String {
    prefersRussian ? russian : english
}
