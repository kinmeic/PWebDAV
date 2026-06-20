import Foundation

enum L {
    private static let lock = NSLock()
    private static var language: InterfaceLanguage = .system

    static var currentLanguage: InterfaceLanguage {
        lock.lock()
        let selectedLanguage = language
        lock.unlock()
        return selectedLanguage
    }

    static func setLanguage(_ newLanguage: InterfaceLanguage) {
        lock.lock()
        language = newLanguage
        lock.unlock()
    }

    static func str(_ key: String) -> String {
        if let bundle = languageBundle() {
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }

        return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }

    static func fmt(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: str(key), locale: Locale.current, arguments: arguments)
    }

    private static func languageBundle() -> Bundle? {
        lock.lock()
        let selectedLanguage = language
        lock.unlock()

        guard let lprojName = selectedLanguage.lprojName else { return nil }
        let candidateNames = [lprojName, lprojName.lowercased()]

        for candidateName in candidateNames {
            if let path = Bundle.module.path(forResource: candidateName, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }

        return nil
    }
}
