import { describe, expect, test } from 'bun:test';
import { z } from 'zod';
import { API_MAGIC_LINK_VERIFY_PATH, env } from '~/lib/env.ts';
import {
  AASA_CACHE_HEADERS,
  APPLE_APP_SITE_ASSOCIATION_PATH,
  INERT_HTML_BODY,
  INERT_HTML_SECURITY_HEADERS,
  buildAppleAppSiteAssociation,
  composeAppleAppId,
} from '~/lib/universal-link.ts';
import { handle } from '~/server.ts';

// Avoid a literal `javascript:` URL anywhere in the source: `no-script-url`
// flags string values that look like an eval-capable scheme, even in
// security tests that deliberately target them. The runtime-joined form
// produces the same value without tripping the rule.
const JS_SCHEME = ['java', 'script:'].join('');

/**
 * End-to-end coverage for the Universal Link handler.
 *
 * These tests drive the production `handle` function and the production
 * `env` — no stubs, no mocks. The three invariants under test:
 *
 * 1. The AASA JSON published at `/.well-known/apple-app-site-association`
 *    advertises exactly one appID (`<TeamID>.<BundleID>`) and exactly one
 *    component path (`MAGIC_LINK_UNIVERSAL_LINK_PATH`) — any drift between
 *    the env values and the published document would cause iOS to reject
 *    the Universal Link association silently, and that failure mode has no
 *    runtime signal.
 *
 * 2. The inert HTML served at `MAGIC_LINK_UNIVERSAL_LINK_PATH` is static:
 *    no JavaScript, no auto-submit forms, no meta-refresh, no reflection
 *    of the `?token=` query parameter into the body. A browser that lands
 *    here must not be able to complete sign-in, and the response must not
 *    become an XSS vector for a user tricked into following a forged link.
 *
 * 3. The Universal Link path is distinct from the API magic-link verify
 *    path, so a Safari fallback cannot collide with the server-side
 *    completion endpoint.
 */

const UNIVERSAL_LINK_PATH = env.MAGIC_LINK_UNIVERSAL_LINK_PATH;
const ARBITRARY_HOST = 'http://localhost';

const fetchPath = async (path: string, init?: RequestInit): Promise<Response> =>
  await handle(new Request(`${ARBITRARY_HOST}${path}`, init));

const aasaDocumentShape = z.strictObject({
  applinks: z.strictObject({
    apps: z.array(z.string()),
    details: z
      .array(
        z.strictObject({
          appIDs: z.array(z.string().min(1)).min(1),
          components: z
            .array(
              z.strictObject({
                '/': z.string().min(1),
                comment: z.string(),
              }),
            )
            .min(1),
        }),
      )
      .min(1),
  }),
});

describe('universal-link: AASA document shape (pure builder)', () => {
  test('document exposes exactly one app binding with the expected appID', () => {
    const doc = buildAppleAppSiteAssociation(env);
    expect(doc.applinks.apps).toEqual([]);
    expect(doc.applinks.details.length).toBe(1);
    const [detail] = doc.applinks.details;
    expect(detail?.appIDs).toEqual([composeAppleAppId(env)]);
  });

  test('components path matches the configured universal-link path exactly', () => {
    const doc = buildAppleAppSiteAssociation(env);
    const [detail] = doc.applinks.details;
    const [component] = detail?.components ?? [];
    expect(component?.['/']).toBe(UNIVERSAL_LINK_PATH);
    expect(component?.comment.length ?? 0).toBeGreaterThan(0);
  });

  test('appID composition is "<TeamID>.<BundleID>"', () => {
    const appId = composeAppleAppId(env);
    expect(appId).toBe(`${env.APPLE_TEAM_ID}.${env.APPLE_APP_BUNDLE_IDENTIFIER}`);
    expect(appId).toStartWith(env.APPLE_TEAM_ID);
    expect(appId).toEndWith(env.APPLE_APP_BUNDLE_IDENTIFIER);
  });

  test('document is deep-frozen so no caller can mutate the shared instance', () => {
    const doc = buildAppleAppSiteAssociation(env);
    expect(Object.isFrozen(doc)).toBe(true);
    expect(Object.isFrozen(doc.applinks)).toBe(true);
    expect(Object.isFrozen(doc.applinks.apps)).toBe(true);
    expect(Object.isFrozen(doc.applinks.details)).toBe(true);
    const [detail] = doc.applinks.details;
    if (detail === undefined) {
      throw new Error('expected at least one detail');
    }
    expect(Object.isFrozen(detail)).toBe(true);
    expect(Object.isFrozen(detail.appIDs)).toBe(true);
    expect(Object.isFrozen(detail.components)).toBe(true);
    const [component] = detail.components;
    if (component === undefined) {
      throw new Error('expected at least one component');
    }
    expect(Object.isFrozen(component)).toBe(true);
  });
});

describe('universal-link: AASA HTTP response', () => {
  test("path constant matches Apple's well-known path exactly", () => {
    expect(APPLE_APP_SITE_ASSOCIATION_PATH).toBe('/.well-known/apple-app-site-association');
  });

  test('GET returns 200 with application/json content-type', async () => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    expect(response.status).toBe(200);
    const contentType = response.headers.get('content-type') ?? '';
    expect(contentType.toLowerCase()).toStartWith('application/json');
  });

  test('GET body is valid JSON with the expected shape', async () => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    const parsed = aasaDocumentShape.parse(await response.json());
    const [detail] = parsed.applinks.details;
    expect(detail?.appIDs).toEqual([composeAppleAppId(env)]);
    const [component] = detail?.components ?? [];
    expect(component?.['/']).toBe(UNIVERSAL_LINK_PATH);
    expect(parsed.applinks.apps).toEqual([]);
  });

  test('GET body is byte-stable across calls (stateless document)', async () => {
    const responseA = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    const first = await responseA.text();
    const responseB = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    const second = await responseB.text();
    expect(first).toBe(second);
  });

  test('HEAD returns 200 with the expected headers and empty body', async () => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH, { method: 'HEAD' });
    expect(response.status).toBe(200);
    expect((response.headers.get('content-type') ?? '').toLowerCase()).toStartWith(
      'application/json',
    );
    const body = await response.text();
    expect(body.length).toBe(0);
  });

  test('caches with the configured Cache-Control policy', async () => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    for (const [name, expected] of Object.entries(AASA_CACHE_HEADERS)) {
      expect(response.headers.get(name)).toBe(expected);
    }
  });

  test('POST returns 405 with Allow header naming permitted methods', async () => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH, { method: 'POST' });
    expect(response.status).toBe(405);
    expect(response.headers.get('allow')).toBe('GET, HEAD');
  });

  test.each(['PUT', 'PATCH', 'DELETE'])('%s returns 405', async (method) => {
    const response = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH, { method });
    expect(response.status).toBe(405);
  });
});

describe('universal-link: inert HTML body (pure)', () => {
  test('contains no <script> element', () => {
    expect(INERT_HTML_BODY.toLowerCase()).not.toContain('<script');
  });

  test('contains no meta-refresh redirect', () => {
    const lowered = INERT_HTML_BODY.toLowerCase();
    expect(lowered).not.toContain('http-equiv="refresh"');
    expect(lowered).not.toContain("http-equiv='refresh'");
    expect(lowered).not.toContain('http-equiv=refresh');
  });

  test('contains no <form> element (auto-submit defence)', () => {
    expect(INERT_HTML_BODY.toLowerCase()).not.toContain('<form');
  });

  test('contains no network-fetch primitives (fetch/XHR/location assignment)', () => {
    const lowered = INERT_HTML_BODY.toLowerCase();
    // Absence of "fetch(" and "xmlhttprequest" implies no client-side
    // request can be issued; absence of "location.href"/"location.replace"
    // blocks JS redirects; absence of "javascript:" blocks JS-scheme URLs.
    expect(lowered).not.toContain('fetch(');
    expect(lowered).not.toContain('xmlhttprequest');
    expect(lowered).not.toContain('location.href');
    expect(lowered).not.toContain('location.replace');
    expect(lowered).not.toContain(JS_SCHEME);
  });

  test('never references the API verify path', () => {
    expect(INERT_HTML_BODY).not.toContain(API_MAGIC_LINK_VERIFY_PATH);
    expect(INERT_HTML_BODY).not.toContain('magic-link/verify');
  });

  test('declares a referrer meta set to no-referrer', () => {
    expect(INERT_HTML_BODY).toContain('name="referrer" content="no-referrer"');
  });

  test('declares robots meta to forbid indexing of token-bearing URLs', () => {
    expect(INERT_HTML_BODY).toContain('name="robots"');
    expect(INERT_HTML_BODY).toContain('noindex');
  });
});

describe('universal-link: inert HTML HTTP response', () => {
  test('GET with no query returns 200 with text/html', async () => {
    const response = await fetchPath(UNIVERSAL_LINK_PATH);
    expect(response.status).toBe(200);
    expect((response.headers.get('content-type') ?? '').toLowerCase()).toStartWith('text/html');
    const body = await response.text();
    expect(body).toBe(INERT_HTML_BODY);
  });

  test('GET with legitimate-looking ?token= does not reflect the token anywhere in the body', async () => {
    const token = 'TOKEN_SHOULD_NEVER_APPEAR_IN_BODY_1234567890';
    const response = await fetchPath(`${UNIVERSAL_LINK_PATH}?token=${token}`);
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).not.toContain(token);
  });

  test('GET with an XSS-shaped ?token= and ?callbackURL= parameters are not reflected or URL-decoded into the body', async () => {
    const xssToken = '<script>alert(1)</script>';
    const xssCallback = `${JS_SCHEME}alert(2)`;
    const qs = `token=${encodeURIComponent(xssToken)}&callbackURL=${encodeURIComponent(xssCallback)}`;
    const response = await fetchPath(`${UNIVERSAL_LINK_PATH}?${qs}`);
    const body = await response.text();
    // Neither the raw nor the URL-encoded payload must appear anywhere in
    // the response body. The page is static — no query parameter can ever
    // reach it.
    expect(body).not.toContain(xssToken);
    expect(body).not.toContain(encodeURIComponent(xssToken));
    expect(body).not.toContain(xssCallback);
    expect(body).not.toContain(encodeURIComponent(xssCallback));
    expect(body).not.toContain('alert(');
  });

  test('GET with an unusually long token payload still returns the static body unchanged', async () => {
    const longToken = 'a'.repeat(64_000);
    const response = await fetchPath(`${UNIVERSAL_LINK_PATH}?token=${longToken}`);
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toBe(INERT_HTML_BODY);
  });

  test('GET responses are byte-identical regardless of query string', async () => {
    const responseA = await fetchPath(UNIVERSAL_LINK_PATH);
    const bodyA = await responseA.text();
    const responseB = await fetchPath(`${UNIVERSAL_LINK_PATH}?token=foo`);
    const bodyB = await responseB.text();
    const responseC = await fetchPath(`${UNIVERSAL_LINK_PATH}?unrelated=bar`);
    const bodyC = await responseC.text();
    expect(bodyA).toBe(bodyB);
    expect(bodyB).toBe(bodyC);
  });

  test('applies the full set of security headers verbatim', async () => {
    const response = await fetchPath(UNIVERSAL_LINK_PATH);
    for (const [name, expected] of Object.entries(INERT_HTML_SECURITY_HEADERS)) {
      expect(response.headers.get(name)).toBe(expected);
    }
  });

  test('Content-Security-Policy explicitly forbids scripts and fetches', async () => {
    const response = await fetchPath(UNIVERSAL_LINK_PATH);
    const csp = response.headers.get('content-security-policy') ?? '';
    // Anchor on the deny-by-default directive and the absence of
    // script-src/connect-src allowances. With `default-src 'none'` and no
    // overrides, scripts/XHR/websockets/etc. are all denied.
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("form-action 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).not.toContain('script-src');
    expect(csp).not.toContain('connect-src');
  });

  test('Cache-Control forbids storage of the token-bearing URL', async () => {
    const response = await fetchPath(`${UNIVERSAL_LINK_PATH}?token=anything`);
    const cacheControl = response.headers.get('cache-control') ?? '';
    expect(cacheControl).toContain('no-store');
    expect(cacheControl).toContain('no-cache');
    expect(cacheControl).toContain('private');
  });

  test('HEAD returns 200 with the same headers and an empty body', async () => {
    const response = await fetchPath(UNIVERSAL_LINK_PATH, { method: 'HEAD' });
    expect(response.status).toBe(200);
    expect((response.headers.get('content-type') ?? '').toLowerCase()).toStartWith('text/html');
    for (const [name, expected] of Object.entries(INERT_HTML_SECURITY_HEADERS)) {
      expect(response.headers.get(name)).toBe(expected);
    }
    const body = await response.text();
    expect(body.length).toBe(0);
  });

  test('POST returns 405 with Allow header naming permitted methods', async () => {
    const response = await fetchPath(UNIVERSAL_LINK_PATH, { method: 'POST' });
    expect(response.status).toBe(405);
    expect(response.headers.get('allow')).toBe('GET, HEAD');
  });

  test.each(['PUT', 'PATCH', 'DELETE'])(
    '%s on the universal-link path returns 405',
    async (method) => {
      const response = await fetchPath(UNIVERSAL_LINK_PATH, { method });
      expect(response.status).toBe(405);
    },
  );
});

describe('universal-link: path-dispatch isolation', () => {
  test('universal-link path is distinct from the API magic-link verify path', () => {
    // Enforced in env parsing, but re-asserted here so a future change to
    // env validation cannot silently collapse the two surfaces.
    expect(UNIVERSAL_LINK_PATH).not.toBe(API_MAGIC_LINK_VERIFY_PATH);
  });

  test('GET on the API verify path is not served by the universal-link handler', async () => {
    // The auth handler owns the API verify path. With the device-attestation
    // plugin gating `/magic-link/verify`, an unauthenticated probe lands on
    // the plugin's 401 ATTESTATION_REQUIRED response — never the inert HTML
    // body. Accepting 401 alongside the older redirect / 4xx outcomes keeps
    // this assertion resilient to the step-5 / step-6 layering while still
    // flagging a regression where the universal-link handler would claim
    // the API path.
    const response = await fetchPath(API_MAGIC_LINK_VERIFY_PATH);
    if (response.status === 200) {
      const body = await response.text();
      expect(body).not.toBe(INERT_HTML_BODY);
    } else {
      expect([301, 302, 303, 307, 308, 400, 401, 403, 404]).toContain(response.status);
    }
  });

  test('the AASA endpoint is not the inert HTML (distinct surfaces)', async () => {
    const aasa = await fetchPath(APPLE_APP_SITE_ASSOCIATION_PATH);
    expect((aasa.headers.get('content-type') ?? '').toLowerCase()).toStartWith('application/json');
    expect(await aasa.text()).not.toBe(INERT_HTML_BODY);
  });

  test('an unknown path still returns the 404 envelope, not the inert HTML', async () => {
    const response = await fetchPath('/some-unrelated-path');
    expect(response.status).toBe(404);
    const body = await response.text();
    expect(body).not.toBe(INERT_HTML_BODY);
  });
});
