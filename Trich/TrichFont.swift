import AppKit
import CoreText
import SwiftUI

/// Mona Sans, Trich's typeface. The variable file ships unmodified in Fonts/ with its license (OFL.txt).
/// Stylistic sets 2 and 3 are always on, so capital I, lowercase l and 1 look different.
enum TrichFont {
    static let family = "Mona Sans"
    private static let fileName = "MonaSans[wdth,wght]"

    /// Loads the bundled file once, for this process only. Test harnesses run outside the app bundle,
    /// so they read the same file from Trich/Fonts in the working directory.
    @discardableResult
    static func register() -> Bool { registered }

    private static let registered: Bool = {
        let bundled = Bundle.main.url(forResource: fileName, withExtension: "ttf", subdirectory: "Fonts")
        let local = URL(fileURLWithPath: "Trich/Fonts/\(fileName).ttf")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: local.path) ? local : nil) else { return false }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered by an earlier call in this process counts as success.
            return NSFont(name: "MonaSans-Regular", size: 12) != nil || !NSFontManager.shared.availableMembers(ofFontFamily: family).isNilOrEmpty
        }
        return true
    }()

    /// A UI font. Width 100 is body text; about 108 suits big headlines. Falls back to the system font.
    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat = 100, tabular: Bool = false) -> NSFont {
        guard register() else { return .systemFont(ofSize: size, weight: weight) }
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltTwoOnSelector],
            [.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltThreeOnSelector],
            [.typeIdentifier: kNumberSpacingType,
             .selectorIdentifier: tabular ? kMonospacedNumbersSelector : kProportionalNumbersSelector],
        ]
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .variation: [axis("wght"): wght(weight), axis("wdth"): width],
            .featureSettings: features,
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return font
    }

    /// The same font for SwiftUI views.
    static func swiftUI(_ size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat = 100, tabular: Bool = false) -> Font {
        Font(ui(size, weight: weight, width: width, tabular: tabular) as CTFont)
    }

    private static func axis(_ tag: String) -> NSNumber {
        NSNumber(value: tag.unicodeScalars.reduce(UInt32(0)) { $0 << 8 | $1.value })
    }

    private static func wght(_ weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case ..<NSFont.Weight.thin: return 200
        case ..<NSFont.Weight.light: return 250
        case ..<NSFont.Weight.regular: return 300
        case ..<NSFont.Weight.medium: return 400
        case ..<NSFont.Weight.semibold: return 500
        case ..<NSFont.Weight.bold: return 600
        case ..<NSFont.Weight.heavy: return 700
        case ..<NSFont.Weight.black: return 800
        default: return 900
        }
    }
}

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
