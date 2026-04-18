import type { Env } from '~/lib/env.ts';

/**
 * Universal Link handler assets.
 *
 * This module owns two interop surfaces consumed by iOS:
 *
 * 1. **`apple-app-site-association` (AASA) file.** Served at
 *    `/.well-known/apple-app-site-association` with `Content-Type:
 *    application/json`. Its `applinks` entry tells iOS that taps on
 *    `https://<MAGIC_LINK_UNIVERSAL_LINK_HOST><MAGIC_LINK_UNIVERSAL_LINK_PATH>`
 *    should be routed into the installed app rather than Safari — the AASA's
 *    `appIDs` entry MUST byte-equal the app's `<TeamID>.<BundleID>` or iOS
 *    refuses to associate the domain. Apple's `swcd` daemon fetches this
 *    document periodically; the server has no opportunity to hand-shake per
 *    request, so correctness at publish time is the only line of defence.
 *
 * 2. **Inert HTML fallback.** Served at `MAGIC_LINK_UNIVERSAL_LINK_PATH`. A
 *    browser that reaches this URL — user taps the link on a device without
 *    the app, the AASA cache hasn't populated yet, the tap originated from
 *    outside a platform-trusted source like Mail — MUST NOT be able to
 *    complete sign-in. The page is a static document: no JavaScript, no
 *    meta-refresh, no auto-submit form, no reflection of the `?token=` query
 *    parameter into the DOM. Only an app holding the Secure-Enclave binding
 *    key can complete the magic-link verify round-trip (enforced in Part 9
 *    steps 5-7); this page's job is simply to refuse to be weaponised by a
 *    captured URL.
 *
 * Both assets are built from `Env` values validated at process-start in
 * `env.ts`. No per-request mutation, no user-controlled input in either body.
 */

/**
 * Standard path at which iOS / `swcd` fetches the AASA document. Fixed by
 * Apple; clients do not negotiate it.
 */
export const APPLE_APP_SITE_ASSOCIATION_PATH = '/.well-known/apple-app-site-association';

/**
 * An AASA `components` entry — the modern path-matching form understood by
 * iOS 13+. `/` holds the path matcher; `comment` is ignored by `swcd` and
 * provides human documentation that survives JSON minification.
 *
 * We intentionally do not constrain the query string: the magic-link emails
 * carry `?token=<value>` and we want iOS to hand the full URL (query
 * included) to the app so it can extract the token. Omitting `?` means
 * "any query is acceptable".
 */
interface AppleAppSiteAssociationComponent {
  readonly '/': string;
  readonly comment: string;
}

interface AppleAppSiteAssociationDetail {
  readonly appIDs: readonly string[];
  readonly components: readonly AppleAppSiteAssociationComponent[];
}

/**
 * Full shape of the JSON document served at
 * `APPLE_APP_SITE_ASSOCIATION_PATH`. `applinks.apps` is intentionally the
 * empty array — Apple's spec requires the key to be present and empty
 * (legacy slot from before the `details` array existed).
 */
export interface AppleAppSiteAssociation {
  readonly applinks: {
    readonly apps: readonly string[];
    readonly details: readonly AppleAppSiteAssociationDetail[];
  };
}

/**
 * Compose the `<TeamID>.<BundleID>` string that the AASA file advertises as
 * the app allowed to claim Universal Links for this domain. Both halves come
 * from `Env` and are validated at process-start — this function performs no
 * additional validation, it only stitches them.
 */
export const composeAppleAppId = (env: Env): string =>
  `${env.APPLE_TEAM_ID}.${env.APPLE_APP_BUNDLE_IDENTIFIER}`;

/**
 * Build the AASA document. The returned object is frozen at every level so a
 * caller cannot accidentally mutate it between requests (AASA is a singleton
 * per process). Shipping a frozen object also exposes any future code path
 * that tried to patch it in flight — which would be a correctness bug.
 */
export const buildAppleAppSiteAssociation = (env: Env): AppleAppSiteAssociation => {
  const appId = composeAppleAppId(env);
  const component: AppleAppSiteAssociationComponent = Object.freeze({
    '/': env.MAGIC_LINK_UNIVERSAL_LINK_PATH,
    comment: 'Magic-link callback handled by the catlaser app',
  });
  const detail: AppleAppSiteAssociationDetail = Object.freeze({
    appIDs: Object.freeze([appId]),
    components: Object.freeze([component]),
  });
  const applinks = Object.freeze({
    apps: Object.freeze([] as string[]),
    details: Object.freeze([detail]),
  });
  return Object.freeze({ applinks });
};

/**
 * Security headers applied to the inert HTML response. Every entry is a
 * deliberate defence against a specific misuse:
 *
 * - `Cache-Control: no-store` / `Pragma: no-cache` — the request URL carries
 *   `?token=<value>` whose lifetime is bounded by the magic-link expiry. The
 *   browser and any intermediate cache must NOT retain the URL or body.
 * - `Referrer-Policy: no-referrer` — if a user navigates away from the page,
 *   the outgoing Referer header would otherwise leak the token-bearing URL
 *   to whatever domain they land on.
 * - `X-Content-Type-Options: nosniff` — forbid MIME sniffing; the page is
 *   HTML and must be rendered as such, never interpreted as a script.
 * - `X-Frame-Options: DENY` — block embedding into a third-party frame,
 *   which would otherwise let an attacker overlay controls on top of a
 *   user's token-bearing URL (clickjacking).
 * - `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline';
 *   base-uri 'none'; form-action 'none'; frame-ancestors 'none'` — the
 *   strictest policy consistent with inline `<style>`: no scripts, no
 *   network fetches, no forms can be submitted from this page, no `<base>`
 *   rewrites, no framing. If a future change accidentally adds a `<script>`
 *   or a `<form action="/api/...">`, the browser refuses to execute it.
 * - `Permissions-Policy` — zero permissions. The page never needs camera,
 *   mic, geolocation, or clipboard; granting none closes the attack surface
 *   if the page is ever reused as a redirect target.
 */
export const INERT_HTML_SECURITY_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  'Cache-Control': 'no-store, no-cache, must-revalidate, private',
  Pragma: 'no-cache',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': [
    "default-src 'none'",
    "style-src 'unsafe-inline'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; '),
  'Permissions-Policy':
    'accelerometer=(), camera=(), geolocation=(), gyroscope=(), microphone=(), payment=(), usb=(), clipboard-read=(), clipboard-write=()',
});

/**
 * Cache headers applied to the AASA response. Apple's `swcd` honours
 * `Cache-Control`; a short max-age keeps the fleet quick to pick up a
 * corrected AASA after a misconfiguration. Public caching is acceptable
 * because the document carries no secrets — it is by definition a public
 * manifest of which app owns this domain.
 */
export const AASA_CACHE_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  'Cache-Control': 'public, max-age=3600',
  'X-Content-Type-Options': 'nosniff',
});

/**
 * Inert HTML body. Static string — every visit returns byte-identical
 * output. Contains no placeholders, no data-bound fields, no JavaScript,
 * and no reference to the `?token=` query parameter. Kept intentionally
 * plain so the document is legible as source even if the strict CSP blocks
 * the stylesheet from applying.
 */
export const INERT_HTML_BODY = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
<title>Open the catlaser app</title>
<style>
:root{color-scheme:light dark}
body{margin:0;padding:2rem;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;line-height:1.45;background:#fafafa;color:#1a1a1a}
main{max-width:32rem;margin:3rem auto;padding:2rem;border-radius:0.75rem;background:#ffffff;box-shadow:0 1px 2px rgba(0,0,0,0.04),0 4px 16px rgba(0,0,0,0.06)}
h1{margin-top:0;font-size:1.4rem}
p{margin:0.8rem 0}
code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:0.95em}
@media (prefers-color-scheme: dark){
  body{background:#121212;color:#f0f0f0}
  main{background:#1e1e1e;box-shadow:none;border:1px solid #2a2a2a}
}
</style>
</head>
<body>
<main>
<h1>Open the catlaser app to finish signing in</h1>
<p>This link is designed to open the catlaser app on your phone. If the app didn't open automatically, it isn't installed on this device or the link was opened outside the app.</p>
<p>Install catlaser from the App Store, then tap the sign-in link in your email again from the same device.</p>
<p>Signing in is only possible from inside the app on the device that requested the link. This page cannot complete sign-in on its own.</p>
</main>
</body>
</html>
`;
