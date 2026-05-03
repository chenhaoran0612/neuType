import Foundation

enum LiveCaptionLanguageValidator {
    static func isDisplayable(_ text: String, as targetLanguage: RealTimeMeetingCaptionLanguage) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let profile = ScriptProfile(text: trimmed)
        switch targetLanguage {
        case .chineseSimplified:
            return profile.cjkRatio >= 0.35 && profile.arabicRatio < 0.20
        case .english:
            return profile.latinRatio >= 0.55 && profile.arabicRatio < 0.20 && profile.cjkRatio < 0.20
        case .arabic:
            return profile.arabicRatio >= 0.45 && profile.cjkRatio < 0.10 && profile.latinRatio < 0.45
        }
    }
}

struct ScriptProfile: Equatable {
    let cjkCount: Int
    let latinCount: Int
    let arabicCount: Int
    let letterCount: Int

    init(text: String) {
        var cjkCount = 0
        var latinCount = 0
        var arabicCount = 0
        var letterCount = 0

        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            letterCount += 1

            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                cjkCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                arabicCount += 1
            default:
                break
            }
        }

        self.cjkCount = cjkCount
        self.latinCount = latinCount
        self.arabicCount = arabicCount
        self.letterCount = max(letterCount, 1)
    }

    var cjkRatio: Double { Double(cjkCount) / Double(letterCount) }
    var latinRatio: Double { Double(latinCount) / Double(letterCount) }
    var arabicRatio: Double { Double(arabicCount) / Double(letterCount) }
}
