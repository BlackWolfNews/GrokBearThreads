// The few things about the website that change. scripts/build.mjs reads them.

/** Where the site will live: a Cloudflare Worker on its own domain (wrangler.jsonc). Not deployed yet. */
export const SITE_URL = "https://threadbear.mikecann.app";

/**
 * The code. The repo's private for now ("eventually, not yet", Mike, 28 Oct 2026), so the
 * GitHub corner is off and every "Fork it" button says "coming soon" and isn't a link. Flip
 * GITHUB_PUBLIC to true once github.com/mikecann/threadbear is public.
 */
export const GITHUB_URL = "https://github.com/mikecann/threadbear";
export const GITHUB_PUBLIC = false;

/**
 * Threadbear for iPhone on the App Store, as https://apps.apple.com/app/id<Apple ID>. Empty
 * until there's an App Store Connect record. Until APP_STORE_LIVE is on, every App Store badge
 * says "Coming soon to the App Store" and isn't a link.
 */
export const APP_STORE_URL = "";
export const APP_STORE_LIVE = false;
