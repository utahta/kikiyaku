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

    // MARK: streamedDisplayText

    private func shown(_ partial: String) -> String {
        UtterancePayload.streamedDisplayText(partial, sourceID: "en-US", targetID: "ja-JP")
    }

    @Test func plainTextStreamsThrough() {
        #expect(shown("訳") == "訳")
        #expect(shown("訳文です。") == "訳文です。")
        #expect(shown("\n 訳文") == "訳文")
    }

    /// An echoed envelope is held back until its opening tag has closed,
    /// then shown without it.
    @Test func anOpeningTagIsHeldBackAndThenDropped() {
        #expect(shown("<") == "")
        #expect(shown("<u source=\"en-US\"") == "")
        #expect(shown("<u source=\"en-US\" target=\"ja-JP\">") == "")
        #expect(shown("<u source=\"en-US\" target=\"ja-JP\">訳文") == "訳文")
    }

    /// The closing tag never shows, however much of it has arrived.
    @Test func aClosingTagIsHiddenAsItArrives() {
        let open = "<u source=\"en-US\" target=\"ja-JP\">"
        #expect(shown(open + "訳文<") == "訳文")
        #expect(shown(open + "訳文</") == "訳文")
        #expect(shown(open + "訳文</u") == "訳文")
        #expect(shown(open + "訳文</u>") == "訳文")
        #expect(shown(open + "訳文</u>\n") == "訳文")
    }

    /// Without an opening tag there is no envelope, and a trailing `<` is
    /// the translation's own.
    @Test func aTrailingAngleIsKeptWhenNothingWasOpened() {
        #expect(shown("a <") == "a <")
        #expect(shown("a </u") == "a </u")
    }

    /// Only `<u …>` is the envelope. A translation that opens with other
    /// markup — a meeting about HTML — shows as it arrives, and so does one
    /// that opens with a `<u>` bearing no attributes, which the request
    /// never sent.
    @Test func otherMarkupAtTheStartIsShown() {
        #expect(shown("<div>") == "<div>")
        #expect(shown("<ul><li>") == "<ul><li>")
        #expect(shown("<u>下線") == "<u>下線")
        #expect(shown("<b") == "<b")
        #expect(shown("< 3") == "< 3")
    }

    /// A `<u …>` that is not this request's envelope — other attributes, or
    /// another pair's — is the translation's own once its tag has closed,
    /// and its closing tag is its own too. unwrap() will keep it at the
    /// end, so hiding it now would make the caption change on the swap.
    @Test func aForeignUElementIsShownOnceItsTagHasClosed() {
        #expect(shown("<u class=\"note\">注") == "<u class=\"note\">注")
        #expect(shown("<u class=\"note\">注</u>") == "<u class=\"note\">注</u>")
        #expect(shown("<u source=\"ja-JP\" target=\"en-US\">訳") == "<u source=\"ja-JP\" target=\"en-US\">訳")
        #expect(shown("<u target=\"ja-JP\" source=\"en-US\">訳") == "訳")
    }
}
