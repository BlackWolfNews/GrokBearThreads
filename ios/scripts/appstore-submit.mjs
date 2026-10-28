#!/usr/bin/env node
// Gets the version being prepared ready for App Review, checks what's still missing, and submits
// it with --submit. Copied from Walkies and Quick Ask (~/dev/me/walkies/scripts/appstore-submit.mjs),
// plus --check.
//
//   node ios/scripts/appstore-submit.mjs --check
//       reads everything and lists what App Review still needs; changes nothing
//   node ios/scripts/appstore-submit.mjs <build number>
//       1. waits until App Store Connect has processed the build (VALID),
//       2. attaches it to the version, sets a manual release and the content rights declaration
//          from ios/appstore/metadata.json, then runs the check
//   node ios/scripts/appstore-submit.mjs <build number> --submit
//       the same, then sends it to App Review. Only once Mike says go.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { api, appId, get, getAll } from "./appstore-lib.mjs";

const meta = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../appstore/metadata.json"), "utf8"));
const [buildNumber] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const submit = process.argv.includes("--submit");
const checkOnly = process.argv.includes("--check");
if (!buildNumber && !checkOnly) {
  console.error("Usage: node ios/scripts/appstore-submit.mjs --check | <build number> [--submit]");
  process.exit(1);
}
const APP_ID = await appId();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDITABLE = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"];

async function preparedVersion() {
  const versions = await get(`/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10`);
  const version = versions.data.find((v) => EDITABLE.includes(v.attributes.appVersionState ?? v.attributes.appStoreState));
  if (!version) throw new Error("no iOS version in a state that can be submitted (run ios/scripts/appstore-metadata.mjs)");
  return version;
}

if (buildNumber) {
  // 1. The build, once processed.
  let build;
  for (let i = 0; ; i++) {
    const found = await get(`/v1/builds?filter[app]=${APP_ID}&filter[version]=${buildNumber}&limit=1`);
    build = found.data[0];
    const state = build?.attributes?.processingState ?? "not there yet";
    if (state === "VALID") break;
    if (state === "FAILED" || state === "INVALID") throw new Error(`build ${buildNumber} is ${state}`);
    if (i === 0 || i % 4 === 0) console.log(`build ${buildNumber}: ${state}, waiting…`);
    await sleep(30_000);
  }
  console.log(`build ${buildNumber}: VALID`);
  if (build.attributes.usesNonExemptEncryption == null) {
    await api("PATCH", `/v1/builds/${build.id}`, { data: { type: "builds", id: build.id, attributes: { usesNonExemptEncryption: false } } });
    console.log("export compliance: no non-exempt encryption");
  }

  // 2. Attach it, and the last listing settings.
  const version = await preparedVersion();
  await api("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  await api("PATCH", `/v1/appStoreVersions/${version.id}`, { data: { type: "appStoreVersions", id: version.id, attributes: { releaseType: "MANUAL" } } });
  await api("PATCH", `/v1/apps/${APP_ID}`, { data: { type: "apps", id: APP_ID, attributes: { contentRightsDeclaration: meta.contentRightsDeclaration } } });
  console.log(`version ${version.attributes.versionString}: build attached, manual release, content rights ${meta.contentRightsDeclaration}`);
}

// 3. What App Review still needs, as far as the API can tell.
const missing = await check();
if (!submit) {
  console.log(missing.length
    ? "\nNot submitting (that's --submit, once Mike says go)."
    : "\nReady as far as the API can tell. Run again with <build> --submit to send it to App Review, once Mike says go.");
  process.exit(0);
}
if (missing.length) {
  console.error("✗ Not submitting while something's missing.");
  process.exit(1);
}

// 4. Submit.
// After a rejection the version stays in the rejected submission (UNRESOLVED_ISSUES). App Review
// only takes it back through that one: a new submission 409s with "Version is not ready to be
// submitted yet" (Walkies, 2026-10-27). So mark its rejected items resolved and resubmit it.
const version = await preparedVersion();
const unresolved = (await get(`/v1/reviewSubmissions?filter[app]=${APP_ID}&filter[state]=UNRESOLVED_ISSUES&limit=1`)).data[0];
if (unresolved) {
  const rejected = await get(`/v1/reviewSubmissions/${unresolved.id}/items`);
  for (const item of rejected.data.filter((i) => i.attributes.state === "REJECTED")) {
    await api("PATCH", `/v1/reviewSubmissionItems/${item.id}`, { data: { type: "reviewSubmissionItems", id: item.id, attributes: { resolved: true } } });
  }
  const done = await api("PATCH", `/v1/reviewSubmissions/${unresolved.id}`, {
    data: { type: "reviewSubmissions", id: unresolved.id, attributes: { submitted: true } },
  });
  console.log(`Resubmitted for review: ${done.data.attributes.state}`);
  process.exit(0);
}
const open = await get(`/v1/reviewSubmissions?filter[app]=${APP_ID}&filter[state]=READY_FOR_REVIEW&limit=1`);
let submission = open.data[0];
if (!submission) {
  submission = (await api("POST", "/v1/reviewSubmissions", {
    data: { type: "reviewSubmissions", attributes: { platform: "IOS" }, relationships: { app: { data: { type: "apps", id: APP_ID } } } },
  })).data;
}
const items = await get(`/v1/reviewSubmissions/${submission.id}/items`);
if (!items.data.length) {
  await api("POST", "/v1/reviewSubmissionItems", {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
}
const done = await api("PATCH", `/v1/reviewSubmissions/${submission.id}`, {
  data: { type: "reviewSubmissions", id: submission.id, attributes: { submitted: true } },
});
console.log(`Submitted for review: ${done.data.attributes.state}`);

/**
 * Reads the listing and prints each thing App Review needs, ticked or not. Returns what's
 * missing. Never changes anything. The App Privacy answers and the declarations that only exist
 * in the website (regulated medical device, the newer age rating questions) aren't in the API, so
 * they're always listed as "check in App Store Connect".
 */
async function check() {
  console.log("\nChecking what App Review needs");
  const missing = [];
  const tick = (ok, what) => {
    console.log(`  ${ok ? "✓" : "✗"} ${what}`);
    if (!ok) missing.push(what);
  };
  const app = (await get(`/v1/apps/${APP_ID}`)).data;
  tick(app.attributes.contentRightsDeclaration != null, `content rights declaration (${app.attributes.contentRightsDeclaration ?? "unset"})`);

  const infos = await getAll(`/v1/apps/${APP_ID}/appInfos`);
  const info = infos.find((i) => EDITABLE.includes(i.attributes.state ?? i.attributes.appStoreState)) ?? infos[0];
  const primary = (await get(`/v1/appInfos/${info.id}/relationships/primaryCategory`)).data?.id;
  tick(!!primary, `primary category (${primary ?? "unset"})`);
  const infoLoc = (await getAll(`/v1/appInfos/${info.id}/appInfoLocalizations`)).find((l) => l.attributes.locale === meta.locale);
  tick(!!infoLoc?.attributes.name, `name (${infoLoc?.attributes.name ?? "unset"})`);
  tick(!!infoLoc?.attributes.privacyPolicyUrl, "privacy policy URL");
  const rating = (await get(`/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
  const unanswered = Object.entries(rating.attributes).filter(([, v]) => v === null).map(([k]) => k);
  tick(unanswered.length === 0, `age rating answered${unanswered.length ? ` (unanswered: ${unanswered.join(", ")})` : ""}`);

  const version = await preparedVersion();
  const v = version.attributes;
  console.log(`  version ${v.versionString} (${v.appVersionState ?? v.appStoreState}), release ${v.releaseType}`);
  tick(v.versionString === meta.version, `version is ${meta.version}`);
  tick(!!v.copyright, "copyright");
  tick(v.releaseType === "MANUAL", "manual release");
  const build = (await get(`/v1/appStoreVersions/${version.id}/build`)).data;
  tick(!!build, `build attached${build ? ` (${build.attributes.version}, ${build.attributes.processingState})` : ""}`);

  const loc = (await getAll(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).find((l) => l.attributes.locale === meta.locale);
  for (const field of ["description", "keywords", "supportUrl"]) tick(!!loc?.attributes[field], `${meta.locale} ${field}`);
  let shots = 0;
  if (loc) {
    const sets = await get(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
    const set = sets.data.find((s) => s.attributes.screenshotDisplayType === "APP_IPHONE_67");
    if (set) shots = (await get(`/v1/appScreenshotSets/${set.id}/appScreenshots`)).data.length;
  }
  tick(shots > 0, `6.9" iPhone screenshots (${shots})`);

  let detail = null;
  try {
    detail = (await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)).data?.attributes;
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  tick(!!detail?.contactEmail && !!detail?.contactPhone && !!detail?.contactFirstName, "App Review contact (name, email, phone)");
  tick(!!detail?.notes, "App Review notes");
  tick(detail?.demoAccountRequired === false, "sign-in not required");

  let priced = false;
  try {
    priced = !!(await get(`/v1/apps/${APP_ID}/appPriceSchedule`)).data;
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  tick(priced, "price set");
  let available = false;
  try {
    available = !!(await get(`/v1/apps/${APP_ID}/appAvailabilityV2`)).data;
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  tick(available, "availability set");

  console.log("  ? App Privacy answers published (not in the API; App Store Connect > App Privacy)");
  console.log("  ? Regulated medical device declaration (not in the API; App Information)");
  console.log(missing.length ? `\n${missing.length} thing(s) missing.` : "\nNothing missing that the API can see.");
  return missing;
}
