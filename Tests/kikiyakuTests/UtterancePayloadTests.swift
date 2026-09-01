import Testing

@testable import kikiyaku

// The envelope stripper exists because a model sometimes copies the prompt's
// <u> wrapper into its answer — and, once recorded into the history, one
// copied wrapper teaches the next hundred. These pin the rules it applies.
struct UtterancePayloadTests {
    private func unwrap(_ response: String) -> (text: String, stripped: Bool) {
        UtterancePayload.unwrap(response, sourceID: "en-US", targetID: "ja-JP")
    }

    @Test func stripsTheRequestsOwnEnvelope() {
        let result = unwrap(#"<u source="en-US" target="ja-JP">訳文</u>"#)
        #expect(result.text == "訳文")
        #expect(result.stripped)
    }

    @Test func attributeOrderAndSpacingDoNotMatter() {
        let result = unwrap(#"<u  target = "ja-JP"   source = "en-US" >訳文</u>"#)
        #expect(result.text == "訳文")
        #expect(result.stripped)
    }

    @Test func leavesAnotherPairsEnvelopeAlone() {
        let other = #"<u source="fr-FR" target="ja-JP">bonjour</u>"#
        let result = unwrap(other)
        #expect(result.text == other)
        #expect(!result.stripped)
    }

    /// `source` must not be found inside `data-source`: a translation that
    /// happens to talk about HTML would otherwise lose its markup.
    @Test func attributeNamesMatchAtABoundary() {
        let markup = #"<u data-source="en-US" data-target="ja-JP">本文</u>"#
        let result = unwrap(markup)
        #expect(result.text == markup)
        #expect(!result.stripped)
    }

    /// No envelope: the text is kept — but surrounding whitespace is always
    /// removed, wrapped or not.
    @Test func trimsWhitespaceEitherWay() {
        let bare = unwrap("\n  訳文  \n")
        #expect(bare.text == "訳文")
        #expect(!bare.stripped)

        let wrapped = unwrap(#"  <u source="en-US" target="ja-JP">  訳文  </u>  "#)
        #expect(wrapped.text == "訳文")
        #expect(wrapped.stripped)
    }

    /// A tag that only opens, or text around the envelope, is not a whole
    /// match and stays as it is.
    @Test func partialEnvelopesAreNotStripped() {
        let unclosed = #"<u source="en-US" target="ja-JP">訳文"#
        #expect(unwrap(unclosed).text == unclosed)

        let surrounded = #"前置き <u source="en-US" target="ja-JP">訳文</u>"#
        #expect(unwrap(surrounded).text == surrounded)
    }

    @Test func wrapProducesTheDocumentedShape() {
        #expect(
            UtterancePayload.wrap("hello", sourceID: "en-US", targetID: "ja-JP")
                == #"<u source="en-US" target="ja-JP">hello</u>"#)
    }
}
