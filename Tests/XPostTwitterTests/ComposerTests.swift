import JavaScriptCore
import Testing

@testable import XPostTwitter

@Suite struct ComposerScriptTests {
  @Test func hiddenNoticesCannotConfirmAPost() throws {
    let context = try #require(JSContext())
    context.evaluateScript(
      """
      const toastSel = '[data-testid="toast"]';
      const node = (text, width, height, visibility) => ({
          innerText: text, getBoundingClientRect: () => ({width, height}),
          style: {visibility}
      });
      const nodes = [
          node('Your post was sent.', 0, 0, 'visible'),
          node('Your post was sent.', 100, 20, 'hidden'),
          node('Your post was sent.', 100, 20, 'collapse'),
          node('Saving your post…', 100, 20, 'visible')
      ];
      const document = {querySelectorAll: () => nodes};
      const getComputedStyle = el => el.style;
      """)
    let notices = context.evaluateScript("(() => { \(visibleNoticesJS) })()")?.toString()
    #expect(context.exception == nil)
    #expect(notices == "Saving your post…")
    #expect(postOutcome(path: "/home", notices: notices ?? "") == .pending)

    context.evaluateScript("nodes.push(node('Your post was sent.', 100, 20, 'visible'));")
    let confirmed = context.evaluateScript("(() => { \(visibleNoticesJS) })()")?.toString()
    #expect(context.exception == nil)
    #expect(postOutcome(path: "/home", notices: confirmed ?? "") == .sent)
  }

  @Test(arguments: ["en", "en-US", "en-GB", "es", "fr", "english", ""])
  func onlyAnEnglishPageCanSubmit(language: String) throws {
    let context = try #require(JSContext())
    context.setObject(language, forKeyedSubscript: "language" as NSString)
    context.evaluateScript("const document = {documentElement: {lang: language}};")
    let accepted = context.evaluateScript("(() => { \(englishPageJS) })()")?.toBool()
    #expect(context.exception == nil)
    #expect(accepted == ["en", "en-US", "en-GB"].contains(language))
  }
}

@Suite struct PostOutcomeTests {
  @Test(arguments: ["Your post was sent.", "Your post was sent. | View", "YOUR POST WAS SENT"])
  func theSentToastIsTheOnlySuccess(notices: String) {
    #expect(postOutcome(path: "/home", notices: notices) == .sent)
    #expect(postOutcome(path: "/compose/post", notices: notices) == .sent)
  }

  // Leaving the composer proves nothing: a dismissed window lands on /home too.
  @Test(arguments: ["/compose/post", "/home", "/blacktop", ""])
  func withoutTheToastNothingIsConfirmed(path: String) {
    #expect(postOutcome(path: path, notices: "") == .pending)
    #expect(postOutcome(path: path, notices: "Something went wrong.") == .pending)
  }

  @Test(arguments: ["/i/flow/login", "/login", "/account/access", "/i/account/login_challenge"])
  func authFlowsAreFailures(path: String) {
    #expect(postOutcome(path: path, notices: "") == .signedOut)
  }
}

@Suite struct DraftTests {
  @Test(arguments: [
    ("hi\n\nhttps://example.com", "hi\n\nhttps://example.com"),
    ("hi\n\n\nhttps://example.com\n", "hi\n\nhttps://example.com"),
    ("a\u{00A0}b", "a b"),
    ("\u{0085}a\u{0085}b\u{0085}", "a b"),
    ("\u{2028}a\u{2029}b\u{3000}", "a b"),
    ("cafe\u{0301}", "caf\u{00E9}"),
  ])
  func acceptsTheRequestedTextHoweverItIsSpaced(held: String, requested: String) {
    #expect(sameDraft(held, requested))
  }

  @Test(arguments: [
    ("hi", "hi\n\nhttps://example.com"),
    ("an unsent draft hi", "hi"),
    ("ab", "a\nb"),
    ("", "hi"),
    ("\u{FEFF}hi", "hi"),
    ("hi\u{FEFF}", "hi"),
    ("a\u{FEFF}b", "a b"),
    ("a \u{0301}b", "a b"),
  ])
  func rejectsAnyOtherText(held: String, requested: String) {
    #expect(!sameDraft(held, requested))
  }
}
