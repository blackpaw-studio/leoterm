import Testing
import UIKit

@testable import Leo

struct DetailLineFitTests {
    private let font = UIFont.preferredFont(forTextStyle: .subheadline)
    private let suffix = " · no update for 21m"

    private func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

    @Test func textThatFitsIsUntouched() {
        let text = "image export" + suffix
        #expect(DetailLineFit.fit(text: text, suffix: suffix, font: font, width: width(text) + 1) == text)
    }

    @Test func overlongTitleTruncatesAndTheSuffixStaysWhole() {
        let text = "image export pipeline nightly" + suffix
        let fitted = DetailLineFit.fit(text: text, suffix: suffix, font: font, width: width("image exp…" + suffix))
        #expect(fitted.hasSuffix(suffix))
        #expect(fitted.contains("…"))
        #expect(width(fitted) <= width("image exp…" + suffix))
    }

    @Test func noRoomEvenForTheSuffixKeepsTheSuffixWhole() {
        #expect(DetailLineFit.fit(text: "title" + suffix, suffix: suffix, font: font, width: 10) == "…" + suffix)
    }

    @Test func textWithoutASuffixIsLeftToTailTruncation() {
        let text = "a very long running task title that will not fit"
        #expect(DetailLineFit.fit(text: text, suffix: nil, font: font, width: 40) == text)
    }
}
