// What the App Store scripts share: Threadbear's App Store Connect app, the API key, and a small
// client. Copied from Walkies and Quick Ask (~/dev/me/walkies/scripts/appstore-lib.mjs). Same
// team and key as Poddle, Walkies and Quick Ask (a team-wide Admin key); it's read from
// ~/.config/poddle and never printed or copied.
import { createPrivateKey, sign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BUNDLE_ID = "com.mikecann.threadbear";
/**
 * "Threadbear" in App Store Connect (App Information > General > Apple ID). Looked up by bundle
 * id when it's empty, so the scripts work as soon as the record exists; THREADBEAR_APP_ID works too.
 */
const KNOWN_APP_ID = process.env.THREADBEAR_APP_ID ?? "";

export const KEY_ID = process.env.ASC_KEY_ID ?? "7SS6J9F98P";
export const ISSUER = process.env.ASC_ISSUER_ID ?? "69a6de6f-a06e-47e3-e053-5b8c7c11a4d1";
export const KEY_PATH = process.env.ASC_KEY ?? join(homedir(), ".config/poddle", `AuthKey_${KEY_ID}.p8`);
/** The App Review contact's email and phone, kept out of git (shared with Poddle and Walkies). */
export const REVIEW_CONTACT_FILE = join(homedir(), ".config/poddle/review-contact.json");

/** Stops with a clear message if the API key's missing. */
export function requireKey() {
  if (!existsSync(KEY_PATH)) {
    console.error(`✗ No App Store Connect API key at ${KEY_PATH}`);
    process.exit(1);
  }
}

let appIdCache = KNOWN_APP_ID;
/** The app's Apple ID, or a clear stop if the App Store Connect record isn't there yet. */
export async function appId() {
  requireKey();
  if (appIdCache) return appIdCache;
  const found = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = found.data.find((a) => a.attributes.bundleId === BUNDLE_ID);
  if (!app) {
    console.error(`✗ There's no App Store Connect app for ${BUNDLE_ID} yet. Make it in App Store Connect > Apps > New App (the API can't).`);
    process.exit(1);
  }
  appIdCache = app.id;
  return app.id;
}

export function reviewContact() {
  try {
    return JSON.parse(readFileSync(REVIEW_CONTACT_FILE, "utf8"));
  } catch {
    return {};
  }
}

let token;
/** An ES256 JWT for the API, made fresh every 15 minutes. */
export function jwt() {
  const now = Math.floor(Date.now() / 1000);
  if (token && token.exp - now > 60) return token.value;
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg: "ES256", kid: KEY_ID, typ: "JWT" });
  const body = enc({ iss: ISSUER, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" });
  const key = createPrivateKey(readFileSync(KEY_PATH, "utf8"));
  const sig = sign("sha256", Buffer.from(`${head}.${body}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  token = { value: `${head}.${body}.${sig}`, exp: now + 15 * 60 };
  return token.value;
}

const API = "https://api.appstoreconnect.apple.com";

export async function api(method, path, body) {
  const res = await fetch(path.startsWith("http") ? path : API + path, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const why = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join("; ") ?? text;
    throw new Error(`${method} ${path} → ${res.status} ${why}`);
  }
  return json;
}

export const get = (path) => api("GET", path);

/** Every page of a list. */
export async function getAll(path) {
  const out = [];
  let next = path;
  while (next) {
    const page = await get(next);
    out.push(...page.data);
    next = page.links?.next;
  }
  return out;
}
