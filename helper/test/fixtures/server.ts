// A stand-in for X's login page and composer with the same selectors the helper relies on.
// Each scenario changes one thing X can do differently.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { text } from "node:stream/consumers";

export const scenarios = [
  "normal",
  "wrongPassword",
  "challengeAfterUsername",
  "challengeAfterPassword",
  "captchaAfterPassword",
  "wrongAccount",
  "uploadFails",
  "ambiguous",
  "hangsAfterPost",
  "passwordFieldDisabled",
  "passwordFieldUnfillable",
  "infoToastThenSent",
  "hiddenStaleToast",
  "localized",
  "ignoresLocale",
  "restoredDraft",
  "keepsFirstLine",
] as const;

export type Scenario = (typeof scenarios)[number];

export interface RecordedPost {
  text: string;
  hasMedia: boolean;
}

const page = (body: string): string =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>X</title></head><body>${body}</body></html>`;

const loginPage = page(`
  <div id="username-step">
    <input autocomplete="username" name="text" type="text">
    <button type="button" id="next">Next</button>
  </div>
  <div id="password-step" hidden>
    <input name="password" type="password">
    <button type="button" data-testid="LoginForm_Login_Button">Log in</button>
  </div>
  <div id="challenge" hidden>
    <p>Enter your phone number or email address</p>
    <input data-testid="ocfEnterTextTextInput" type="text">
  </div>
  <div id="alert" role="alert" hidden></div>
  <script>
    const post = (path, body) => fetch(path, {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify(body)}).then(r => r.json());
    document.getElementById("next").onclick = async () => {
      const username = document.querySelector('input[autocomplete="username"]').value;
      const reply = await post("/login/username", {username});
      if (reply.challenge) { document.getElementById("challenge").hidden = false; return; }
      document.getElementById("username-step").hidden = true;
      document.getElementById("password-step").hidden = false;
      if (reply.disablePassword) document.querySelector('input[name="password"]').disabled = true;
      if (reply.checkboxPassword) document.querySelector('input[name="password"]').type = "checkbox";
    };
    document.querySelector('[data-testid="LoginForm_Login_Button"]').onclick = async () => {
      const password = document.querySelector('input[name="password"]').value;
      const reply = await post("/login/password", {password});
      if (reply.challenge) { document.getElementById("challenge").hidden = false; return; }
      if (reply.captcha) { location.href = "/account/access"; return; }
      if (reply.error) { const a = document.getElementById("alert"); a.textContent = reply.error; a.hidden = false; return; }
      location.href = "/compose/post";
    };
  </script>`);

const composerPage = page(`
  <a href="/home">Home</a>
  <div data-testid="tweetTextarea_0" contenteditable="true" style="min-height:2em;border:1px solid"></div>
  <input data-testid="fileInput" type="file" style="display:none">
  <div id="attachments" hidden data-testid="attachments">1 image</div>
  <div id="upload-alert" role="alert" hidden></div>
  <button data-testid="tweetButton" aria-disabled="true">Post</button>
  <div id="toast" data-testid="toast" hidden></div>
  <!--SCENARIO-->
  <script>
    const box = document.querySelector('[data-testid="tweetTextarea_0"]');
    const button = document.querySelector('[data-testid="tweetButton"]');
    let media = null;
    const refresh = () => button.setAttribute("aria-disabled", box.innerText.trim() ? "false" : "true");
    box.addEventListener("input", refresh);
    document.querySelector('[data-testid="fileInput"]').addEventListener("change", async (event) => {
      const file = event.target.files[0];
      const reply = await fetch("/media", {method: "POST", body: await file.arrayBuffer()}).then(r => r.json());
      if (reply.error) { const a = document.getElementById("upload-alert"); a.textContent = reply.error; a.hidden = false; return; }
      media = reply.id;
      document.getElementById("attachments").hidden = false;
    });
    button.onclick = async () => {
      if (button.getAttribute("aria-disabled") === "true") return;
      button.setAttribute("aria-disabled", "true");
      const reply = await fetch("/post", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({text: box.innerText.replace(/\\n{2,}/g, "\\n\\n").trim(), media})}).then(r => r.json());
      if (reply.hang) return;
      const t = document.getElementById("toast");
      if (reply.first) { t.textContent = reply.first; t.hidden = false; }
      const show = () => { if (reply.toast) { t.textContent = reply.toast; t.hidden = false; } setTimeout(() => { location.href = "/home"; }, 400); };
      setTimeout(show, reply.first ? 1500 : 0);
    };
  </script>`);

// Markup a scenario adds to the composer page, after the composer and before its script.
const composerExtras: Partial<Record<Scenario, string>> = {
  hiddenStaleToast: '<div data-testid="toast" hidden>Your post was sent.</div>',
  restoredDraft: `<script>
    document.querySelector('[data-testid="tweetTextarea_0"]').innerText = "an unsent draft";
  </script>`,
  keepsFirstLine: `<script>
    const draft = document.querySelector('[data-testid="tweetTextarea_0"]');
    draft.addEventListener("input", () => {
      const first = draft.innerText.split("\\n")[0];
      if (draft.innerText !== first) draft.innerText = first;
    });
  </script>`,
};

const homePage = page(`<a href="/home">Home</a><p>Home timeline</p>`);

function cookies(request: IncomingMessage): Map<string, string> {
  const jar = new Map<string, string>();
  for (const pair of (request.headers.cookie ?? "").split(";")) {
    const [name, ...rest] = pair.trim().split("=");
    if (name) jar.set(name, rest.join("="));
  }
  return jar;
}

export class FakeX {
  scenario: Scenario = "normal";
  readonly accountID = "442174011";
  readonly username = "fixture_user";
  readonly password = "fixture-password";
  readonly posts: RecordedPost[] = [];
  /** The user agent and client hints of every request, to check how the browser presents. */
  readonly agents: { userAgent: string; clientHints: string }[] = [];
  loginAttempts = 0;
  composerLanguage = "en";
  private server: Server | undefined;

  get baseURL(): string {
    const address = this.server?.address();
    if (address === null || address === undefined || typeof address === "string") {
      throw new Error("server is not listening");
    }
    return `http://127.0.0.1:${(address satisfies AddressInfo).port}`;
  }

  async start(): Promise<void> {
    this.server = createServer((request, response) => void this.handle(request, response));
    await new Promise<void>((resolve) => this.server?.listen(0, "127.0.0.1", resolve));
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }

  reset(scenario: Scenario): void {
    this.scenario = scenario;
    this.posts.length = 0;
    this.agents.length = 0;
    this.loginAttempts = 0;
    this.composerLanguage = "en";
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://fixture");
    this.agents.push({
      userAgent: request.headers["user-agent"] ?? "",
      clientHints: String(request.headers["sec-ch-ua"] ?? ""),
    });
    const json = (body: object, headers: Record<string, string> = {}): void => {
      response.writeHead(200, { "content-type": "application/json", ...headers });
      response.end(JSON.stringify(body));
    };
    const html = (body: string): void => {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(body);
    };
    const signedIn = cookies(request).has("auth_token");

    switch (`${request.method} ${url.pathname}`) {
      case "GET /i/flow/login":
        return html(loginPage);
      case "GET /account/access":
        return html(page("<p>Verify you are human</p>"));
      case "GET /home":
        return html(homePage);
      case "GET /compose/post":
        if (!signedIn) {
          response.writeHead(302, {
            location: "/i/flow/login?redirect_after_login=%2Fcompose%2Fpost",
          });
          response.end();
          return;
        }
        this.composerLanguage =
          this.scenario === "ignoresLocale" ||
          (this.scenario === "localized" &&
            (url.searchParams.get("lang") !== "en" ||
              !request.headers["accept-language"]?.startsWith("en")))
            ? "es"
            : "en";
        return html(
          composerPage
            .replace("<!--SCENARIO-->", composerExtras[this.scenario] ?? "")
            .replace('<html lang="en">', `<html lang="${this.composerLanguage}">`),
        );
      case "POST /login/username": {
        await text(request);
        this.loginAttempts += 1;
        return json({
          challenge: this.scenario === "challengeAfterUsername",
          disablePassword: this.scenario === "passwordFieldDisabled",
          checkboxPassword: this.scenario === "passwordFieldUnfillable",
        });
      }
      case "POST /login/password": {
        const body: unknown = JSON.parse(await text(request));
        const password =
          typeof body === "object" && body !== null && "password" in body
            ? body.password
            : undefined;
        if (this.scenario === "challengeAfterPassword") return json({ challenge: true });
        if (this.scenario === "captchaAfterPassword") return json({ captcha: true });
        if (this.scenario === "wrongPassword" || password !== this.password) {
          return json({ error: "Wrong password!" });
        }
        const id = this.scenario === "wrongAccount" ? "999" : this.accountID;
        response.setHeader("set-cookie", [
          "auth_token=fixture-token; Path=/; HttpOnly",
          `twid=u%3D${id}; Path=/`,
        ]);
        return json({ ok: true });
      }
      case "POST /media":
        await text(request);
        if (this.scenario === "uploadFails") return json({ error: "Media upload failed." });
        return json({ id: "m1" });
      case "POST /post": {
        const body: unknown = JSON.parse(await text(request));
        const record = typeof body === "object" && body !== null ? body : {};
        this.posts.push({
          text: "text" in record && typeof record.text === "string" ? record.text : "",
          hasMedia: "media" in record && record.media !== null,
        });
        if (this.scenario === "hangsAfterPost") return json({ hang: true });
        if (this.scenario === "ambiguous" || this.scenario === "hiddenStaleToast") return json({});
        if (this.scenario === "infoToastThenSent") {
          return json({ first: "Saving your post…", toast: "Your post was sent." });
        }
        return json({
          toast: this.composerLanguage === "en" ? "Your post was sent." : "Tu post se envió.",
        });
      }
      default:
        response.writeHead(404);
        response.end();
    }
  }
}
