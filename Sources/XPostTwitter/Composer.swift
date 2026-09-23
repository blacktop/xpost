import Foundation
import XPostCore

/// Attaches an image through X's own file chooser, which the browser answers for the page.
@MainActor
func attach(_ path: String, to browser: Browser) async throws {
  let file = URL(fileURLWithPath: path)
  guard FileManager.default.isReadableFile(atPath: file.path) else {
    throw Failure("cannot read image \(path)")
  }
  browser.pendingUploads = [file]
  let opened = try await browser.js(
    """
    const input = document.querySelector(sel);
    if (input) input.click();
    return !!input;
    """, arguments: ["sel": fileInputSelector])
  guard opened as? Bool == true else {
    throw Failure("composer has no file input matching \(fileInputSelector)")
  }
  for _ in 0..<10 where !browser.pendingUploads.isEmpty {
    try await Task.sleep(for: .seconds(0.5))
  }
  guard browser.pendingUploads.isEmpty else {
    throw Failure("X never opened its file chooser, so nothing was attached")
  }
  try await browser.waitFor(attachmentsSelector, timeout: 30)
  browser.log.note("image attached: \(file.lastPathComponent)")
}

// Draft.js reads pasted text from clipboardData; execCommand is the fallback when WebKit
// refuses the synthetic paste. Both return what the composer holds afterwards.
let insertTextJS = """
  const el = document.querySelector(sel);
  el.focus();
  const read = () => el.innerText.replace(/\\n$/, "");
  const settle = () => new Promise(r => setTimeout(r, 300));

  const data = new DataTransfer();
  data.setData("text/plain", text);
  const init = {clipboardData: data, bubbles: true, cancelable: true};
  el.dispatchEvent(new ClipboardEvent("paste", init));
  await settle();
  if (read().length > 0) return {method: "paste", value: read()};

  const lines = text.split("\\n");
  for (let i = 0; i < lines.length; i++) {
      if (i > 0) document.execCommand("insertLineBreak");
      if (lines[i]) document.execCommand("insertText", false, lines[i]);
  }
  await settle();
  return {method: "execCommand", value: read()};
  """

/// Whether the composer holds exactly the requested text. Whitespace may differ, since
/// Draft.js renders blank lines as extra line breaks; every other character must match, so
/// a partial paste or a restored draft stops the post. String comparison already treats
/// composed and decomposed accents as equal. Both backends split on Unicode White_Space
/// scalars; U+FEFF is content, not whitespace.
func sameDraft(_ held: String, _ requested: String) -> Bool {
  func words(_ text: String) -> [String] {
    text.unicodeScalars.split(whereSeparator: \.properties.isWhitespace).map(String.init)
  }
  return words(held) == words(requested)
}

/// Fills the open composer with the request and presses Post.
@MainActor
func compose(_ request: Request, in browser: Browser) async throws {
  let log = browser.log
  if !request.imagePath.isEmpty {
    try await attach(request.imagePath, to: browser)
    log.report("alt text is not applied on X yet")
  }

  let inserted = try await browser.js(
    insertTextJS, arguments: ["sel": textareaSelector, "text": request.text])
  guard let result = inserted as? [String: Any], let value = result["value"] as? String,
    !value.isEmpty
  else { throw Failure("composer stayed empty after paste and execCommand") }
  // The body stays out of the log and errors: the unified log is readable by anyone on
  // this Mac.
  guard sameDraft(value, request.text) else {
    throw Failure(
      "composer holds \(value.count) characters, not the \(request.text.count) requested; "
        + "nothing was posted")
  }
  log.note("composer filled via \(result["method"] ?? "?"): \(value.count) characters")

  // The button stays disabled while an attachment uploads.
  try await browser.waitFor(
    "\(postButtonSelector):not([aria-disabled=\"true\"])",
    timeout: request.imagePath.isEmpty ? 10 : 90)
  log.note("post button is enabled")

  // X's composer looks up link previews and mentions after text lands; let it settle.
  try await Task.sleep(for: .seconds(1.5))
  // A requested locale can be overridden by account settings. Stop before submitting
  // if the page cannot provide the English confirmation we know how to recognize.
  guard try await browser.js(englishPageJS) as? Bool == true else {
    throw Failure("X did not open an English composer; nothing was posted")
  }
  try await browser.click(selector: postButtonSelector)
  log.note("pressed Post")
  try await confirmPosted(browser)
}

/// What the page says about the post after pressing the button.
enum PostOutcome: Equatable {
  /// No evidence either way yet: still on the composer, or somewhere unexpected.
  case pending
  /// X went to its sign-in or account-challenge flow instead of posting.
  case signedOut
  /// X confirmed the post with its toast.
  case sent
}

/// X's toast for a successful post, as observed on 2026-09-21.
private let sentNotice = "your post was sent"

let englishPageJS = "return /^en(?:-|$)/i.test(document.documentElement.lang);"

let visibleNoticesJS = """
  const selector = `${toastSel}, [role=alert], [role=alertdialog]`;
  return [...document.querySelectorAll(selector)]
      .filter(el => {
          const box = el.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && getComputedStyle(el).visibility === "visible";
      })
      .map(el => el.innerText).join(" | ");
  """

/// Where X sends a browser that has to sign in or prove something first.
let authFlowPaths = ["/i/flow/", "/login", "/account/access", "/i/account/"]

func postOutcome(path: String, notices: String) -> PostOutcome {
  if notices.lowercased().contains(sentNotice) {
    return .sent
  }
  if authFlowPaths.contains(where: path.hasPrefix) {
    return .signedOut
  }
  return .pending
}

/// A sent post shows "Your post was sent." and closes the composer; a rejected one stays
/// there with an error toast. Leaving the composer is no proof by itself: a sign-in
/// redirect or a dismissed window does that too.
@MainActor
func confirmPosted(_ browser: Browser) async throws {
  let deadline = Date().addingTimeInterval(20)
  var notices = ""
  while Date() < deadline {
    let seen = try? await browser.js(
      visibleNoticesJS, arguments: ["toastSel": toastSelector])
    if let seen = seen as? String, !seen.isEmpty { notices = seen }
    let url = browser.webView.url
    switch postOutcome(path: url?.path ?? "", notices: notices) {
    case .pending:
      break
    case .signedOut:
      throw Failure("X asked to sign in instead of posting (url: \(url?.absoluteString ?? "none"))")
    case .sent:
      browser.log.note("posted (X said: \(notices))")
      return
    }
    try await Task.sleep(for: .seconds(0.5))
  }
  throw Failure(
    "X did not confirm the post within 20s (url: \(browser.webView.url?.absoluteString ?? "none"); "
      + "X said: \(notices.debugDescription))")
}
