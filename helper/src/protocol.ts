// The request xpost writes to the helper's stdin and the result it reads from stdout.
// Both are one JSON document. Credentials travel only here, never in arguments or logs.

export type Operation = "check" | "post";

export interface HelperRequest {
  op: Operation;
  /** Where X lives; tests point this at a fixture server. */
  baseURL: string;
  username: string;
  /** Used only when the saved state does not sign in. */
  password?: string;
  /** X's numeric user id that the signed-in account must have. */
  accountID: string;
  /** Playwright storage state: read when present, written after a verified password login. */
  stateFile?: string;
  text?: string;
  imagePath?: string;
  /** Budget for the whole run. */
  timeoutMs: number;
  /** Written when the run fails, so the page state can be inspected. */
  screenshotPath?: string;
}

export type SessionSource = "state" | "password";

export type FailureReason =
  | "notSignedIn"
  | "loginFailed"
  | "challenge"
  | "wrongAccount"
  | "composerUnavailable"
  | "uploadFailed"
  | "ambiguous"
  | "timeout"
  | "internal";

export type HelperResult =
  | { outcome: "checked"; accountID: string; sessionSource: SessionSource; stateSaved: boolean }
  | {
      outcome: "posted";
      accountID: string;
      sessionSource: SessionSource;
      stateSaved: boolean;
      notice: string;
    }
  | { outcome: "failed"; reason: FailureReason; detail: string; screenshot?: string };

export class RequestError extends Error {}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new RequestError(`${key} must be a string`);
  return value;
}

function requiredString(record: Record<string, unknown>, key: string): string {
  const value = optionalString(record, key);
  if (value === undefined || value === "") throw new RequestError(`${key} is required`);
  return value;
}

/** Validates the JSON xpost sent, so a malformed request fails before a browser starts. */
export function parseRequest(text: string): HelperRequest {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    throw new RequestError("request is not JSON");
  }
  if (!isRecord(json)) throw new RequestError("request must be an object");

  const op = requiredString(json, "op");
  if (op !== "check" && op !== "post") throw new RequestError(`unknown op ${op}`);
  const timeoutMs = json["timeoutMs"];
  if (typeof timeoutMs !== "number" || !(timeoutMs > 0)) {
    throw new RequestError("timeoutMs must be a positive number");
  }
  const accountID = requiredString(json, "accountID");
  if (!/^\d+$/.test(accountID)) throw new RequestError("accountID must be X's numeric user id");

  const request: HelperRequest = {
    op,
    baseURL: optionalString(json, "baseURL") ?? "https://x.com",
    username: requiredString(json, "username"),
    accountID,
    timeoutMs,
  };
  const password = optionalString(json, "password");
  if (password !== undefined) request.password = password;
  const stateFile = optionalString(json, "stateFile");
  if (stateFile !== undefined) request.stateFile = stateFile;
  const screenshotPath = optionalString(json, "screenshotPath");
  if (screenshotPath !== undefined) request.screenshotPath = screenshotPath;
  const imagePath = optionalString(json, "imagePath");
  if (imagePath !== undefined) request.imagePath = imagePath;
  if (op === "post") {
    request.text = requiredString(json, "text");
  }
  return request;
}
