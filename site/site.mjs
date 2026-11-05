// The few things about the website that change. scripts/build.mjs reads them.

/** Where the site lives: a Cloudflare Worker on its own domain (wrangler.jsonc). */
export const SITE_URL = "https://threadbear.mikecann.app";

/**
 * The code. Public since 5 Nov 2026, launch day. Turned off, the GitHub corner goes and every
 * "Fork it" button says "coming soon" and isn't a link, as it did while the repo was private.
 */
export const GITHUB_URL = "https://github.com/mikecann/threadbear";
export const GITHUB_PUBLIC = true;

/**
 * Threadbear for iPhone on the App Store, as https://apps.apple.com/app/id<Apple ID>. Empty
 * until there's an App Store Connect record. Until APP_STORE_LIVE is on, every App Store badge
 * says "Coming soon to the App Store" and isn't a link.
 */
export const APP_STORE_URL = "https://apps.apple.com/app/id6827837354";
export const APP_STORE_LIVE = true;

/**
 * The launch video's YouTube id (the part after watch?v=), shown in the home page's "Watch me go
 * through it". Empty until it's up: the page shows a stand-in card with no link. Once it's set,
 * the card links to it and plays it in place through youtube-nocookie.com, and headers.mjs lets
 * that player and YouTube's thumbnail through the CSP.
 */
export const LAUNCH_VIDEO_ID = "HCR6jqR0LEI";
