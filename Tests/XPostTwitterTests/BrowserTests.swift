import Foundation
import JavaScriptCore
import Testing

@testable import XPostTwitter

@Suite struct SignInStepTests {
  @Test(arguments: [
    ("challenge_response", ""),
    ("", "one-time-code"),
  ])
  func selectsUsePasswordOnEmailCodeScreen(name: String, autocomplete: String) throws {
    let context = try #require(JSContext())
    context.setObject(name, forKeyedSubscript: "codeName" as NSString)
    context.setObject(autocomplete, forKeyedSubscript: "codeAutocomplete" as NSString)
    context.evaluateScript(
      """
      const user = 'fixture';
      const done = [];
      const button = {
          innerText: 'Use password',
          getBoundingClientRect: () => ({x: 10, y: 20, width: 100, height: 40}),
          contains: () => false,
      };
      const document = {
          querySelectorAll: selector => selector === 'input'
              ? [{type: 'text', name: codeName, autocomplete: codeAutocomplete,
                  placeholder: '', offsetParent: {}, value: ''}]
              : [button],
          elementFromPoint: () => button,
          visibilityState: 'visible',
      };
      """)

    let result = context.evaluateScript("(() => { \(signInStepJS) })()")?.toDictionary()
    #expect(context.exception == nil)
    let target = try #require(result?["target"] as? [String: Any])
    #expect(target["label"] as? String == "Use password")
    #expect(target["x"] as? Double == 60)
    #expect(target["y"] as? Double == 40)
  }
}
