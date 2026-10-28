# Sign in to the Convex panel through Chrome

When Convex needs you to sign in, the panel shows a large, centred
**Sign in through Chrome** button. **Sign in here instead** opens the
embedded form. The panel's bar keeps a smaller sign-in button for changing
accounts and a Reload button.

The sign-in window lists the steps, each with its own button. The first
time:

1. **Add the extension to Chrome (one time only).** Open
   `chrome://extensions` in Chrome (**Copy chrome://extensions** puts the
   address on the clipboard), turn on **Developer mode**, click **Load
   unpacked** and pick the folder **Show folder in Finder** reveals,
   `~/Library/Application Support/Threadbear/ChromeSignIn`. Its name in
   Chrome is **Threadbear Convex Sign-in**.
2. **Open the Convex login in Chrome** with **Open in Chrome**.
3. On the page that opens, click Chrome's puzzle piece, then **Threadbear
   Convex Sign-in**, and log in to Convex as normal. The panel signs in
   by itself; close Chrome's tab and click **Done**.

Once a sign-in has come back, the window remembers the extension is there
and shows only the last two steps (**Set up the extension again** brings
step 1 back). The panel keeps its own session between
app launches; other Convex panels use the same website data store. Reload
an already-open panel if it is still showing the login page.

The extension uses your normal Convex login flow in Chrome and returns a
fresh authorization callback to the panel. Convex exchanges the one-use
code itself and sets its session cookie in the panel. The extension has
no cookie, storage or content-script permissions, and never imports saved
OAuth tokens or reads Chrome's profile or Keychain. Its redirect rule is
limited to the dashboard's callback in the tab you chose. Chrome's site
permission is for `dashboard.convex.dev`; the rule itself matches only
`/api/auth/callback`.

The app listens on `127.0.0.1` at a random port for up to five minutes,
checks the sign-in's random nonce and exact return path, and accepts one
callback. Cancel closes the listener. The extension's tab rule disappears
when the tab closes or after ten minutes. Close Chrome's return tab when
you are done.

This supports the hosted Convex dashboard. Local anonymous dashboards
do not need it. The real-login check still needs the installed extension
and a completed sign-in. Tests use synthetic codes in a disposable Chrome
profile, plus actual HTTP requests to the app's loopback listener.

For development:

```
./check.sh --app
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node --test app/Tests/ChromeSignInTests/browser.test.mjs
```

The Chrome test loads a disposable copy of the extension into headless
Chrome for Testing. It proves that the callback is redirected before the
dashboard consumes it, another tab is unaffected, and closing the tab
removes the rule. It makes no requests to the real Convex login service.

The extension is needed because Convex's callback is on its own HTTPS
domain, while Apple's HTTPS authentication callbacks require an associated
domain. References: [Apple's HTTPS callback contract](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:)),
[Chrome's declarative redirects](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest),
and the [Convex callback handler](https://github.com/get-convex/convex-backend/blob/main/npm-packages/dashboard/src/pages/api/auth/callback.ts).
