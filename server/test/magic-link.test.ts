import { createHash } from 'node:crypto';
import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { user, verification } from '~/db/schema.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { resolveAllowedCallbackUrl } from '~/lib/magic-link.ts';

/**
 * End-to-end coverage for the magic-link plugin. Three invariants dominate
 * this file:
 *
 * 1. The emailed URL is ALWAYS the Universal Link URL, never the API
 *    verify endpoint and never influenced by client-supplied body fields.
 * 2. Client-submitted `callbackURL` values are allowlisted to the exact
 *    Universal Link URL; any other host, path, scheme, or relative value
 *    is rejected with 403 `MAGIC_LINK_CALLBACK_FORBIDDEN`.
 * 3. Tokens land in the `verification` table hashed (base64url-no-pad
 *    SHA-256); the wire token stays plaintext so the email is usable.
 *
 * Every test drives the real better-auth instance via `createAuth()` and
 * the real Postgres instance `docker compose up` provisions for this
 * suite. No plugin internals are bypassed.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';
const allowedCallbackURL = resolveAllowedCallbackUrl(env);

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

const successStatusShape = z.object({
  status: z.literal(true),
});

const verifyBodyShape = z.object({
  token: z.string().min(1),
  user: z.looseObject({ id: z.string().min(1), email: z.string().optional() }),
  session: z.looseObject({ id: z.string().min(1) }),
});

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
  // Cascade drops sessions/accounts; verification rows are keyed by token
  // digest, so only `sendCount > 0` tests care about cleaning them — left
  // intact so "token already redeemed" state survives across tests that
  // expect it.
};

class RecordingDelivery implements MagicLinkDelivery {
  private readonly calls: MagicLinkEmailPayload[] = [];
  public lastError: Error | undefined;

  // eslint-disable-next-line @typescript-eslint/require-await
  public async send(payload: MagicLinkEmailPayload): Promise<void> {
    if (this.lastError !== undefined) {
      throw this.lastError;
    }
    this.calls.push(payload);
  }

  public callCount(): number {
    return this.calls.length;
  }

  public latest(): MagicLinkEmailPayload {
    const last = this.calls.at(-1);
    if (last === undefined) {
      throw new Error('RecordingDelivery had no calls');
    }
    return last;
  }

  public reset(): void {
    this.calls.length = 0;
    this.lastError = undefined;
  }
}

let delivery: RecordingDelivery;
let auth: ReturnType<typeof createAuth>;

const post = async (
  body: unknown,
  extraHeaders: Record<string, string> = {},
): Promise<{ response: Response; body: unknown }> => {
  const init: RequestInit = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: trustedOrigin, ...extraHeaders },
    body: JSON.stringify(body),
  };
  const response = await auth.handler(new Request(SIGN_IN_URL, init));
  const text = await response.text();
  const parsed: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { response, body: parsed };
};

const verifyViaToken = async (token: string): Promise<Response> => {
  const url = new URL(VERIFY_URL_BASE);
  url.searchParams.set('token', token);
  return await auth.handler(new Request(url.toString(), { method: 'GET' }));
};

const base64UrlNoPadSha256 = (input: string): string =>
  createHash('sha256')
    .update(input, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

beforeAll(() => {
  delivery = new RecordingDelivery();
  auth = createAuth({ magicLinkDelivery: delivery });
});

beforeEach(() => {
  delivery.reset();
});

describe('magic-link: endpoint presence', () => {
  test('POST /sign-in/magic-link responds under the auth base path', async () => {
    const { response } = await post({ email: 'mounted@example.com' });
    expect(response.status).not.toBe(404);
    await clearEmail('mounted@example.com');
  });

  test('GET /magic-link/verify responds under the auth base path', async () => {
    // Unknown token → plugin redirects to callbackURL with ?error=INVALID_TOKEN.
    // Status is a redirect, not 404 — that proves the route is mounted.
    const response = await verifyViaToken('does-not-exist');
    expect(response.status).not.toBe(404);
  });
});

describe('magic-link: emailed URL construction', () => {
  test('no body.callbackURL → emailed URL is the Universal Link URL with token', async () => {
    const email = 'construct-default@example.com';
    const { response, body } = await post({ email });
    expect(response.status).toBe(200);
    expect(successStatusShape.parse(body).status).toBe(true);
    expect(delivery.callCount()).toBe(1);

    const { magicLink, token } = delivery.latest();
    const parsed = new URL(magicLink);
    expect(parsed.protocol).toBe('https:');
    expect(parsed.host).toBe(env.MAGIC_LINK_UNIVERSAL_LINK_HOST);
    expect(parsed.pathname).toBe(env.MAGIC_LINK_UNIVERSAL_LINK_PATH);
    expect(parsed.searchParams.get('token')).toBe(token);
    // The plugin's internal /magic-link/verify endpoint MUST NOT appear in
    // the email — that would leak the server origin and bypass the
    // Universal Link routing.
    expect(parsed.host).not.toBe('localhost');
    expect(parsed.pathname).not.toContain('/magic-link/verify');
    await clearEmail(email);
  });

  test('allowlisted body.callbackURL → same emailed URL, ignoring client submission', async () => {
    const email = 'construct-explicit@example.com';
    // Submit the allowlisted URL; the emailed URL must still be the
    // deterministically-constructed one. This exercises the invariant
    // that `ctx.body.callbackURL` does not influence the email.
    await post({ email, callbackURL: allowedCallbackURL });
    const { magicLink } = delivery.latest();
    const parsed = new URL(magicLink);
    expect(parsed.host).toBe(env.MAGIC_LINK_UNIVERSAL_LINK_HOST);
    expect(parsed.pathname).toBe(env.MAGIC_LINK_UNIVERSAL_LINK_PATH);
    await clearEmail(email);
  });
});

describe('magic-link: callbackURL allowlist (phishing-relay defence)', () => {
  // Two defensive layers protect this route:
  //
  //  - better-auth's built-in `originCheckMiddleware` runs on every POST
  //    and rejects a `callbackURL` whose ORIGIN (scheme + host + port)
  //    is not in `trustedOrigins` with `INVALID_CALLBACK_URL` / 403.
  //    This layer handles the "host not ours" class of attacks.
  //
  //  - Our `buildBeforeHook` in `auth-hooks.ts` runs after the router
  //    middleware and rejects any string that isn't a byte-for-byte
  //    match of the configured Universal Link URL with
  //    `MAGIC_LINK_CALLBACK_FORBIDDEN` / 403. This layer handles the
  //    "host is trusted but path / shape is wrong" class.
  //
  // Each test below is annotated with which layer it exercises. Both
  // layers terminate the request before `sendMagicLink` runs, so the
  // `delivery.callCount() === 0` assertion is the real phishing-relay
  // invariant.

  test('exact allowlisted URL → accepted', async () => {
    const email = 'allow-exact@example.com';
    const { response } = await post({ email, callbackURL: allowedCallbackURL });
    expect(response.status).toBe(200);
    expect(delivery.callCount()).toBe(1);
    await clearEmail(email);
  });

  test('different host → 403 (layer 1: built-in originCheckMiddleware)', async () => {
    const { response, body } = await post({
      email: 'reject-evil-host@example.com',
      callbackURL: 'https://evil.example/sign-in',
    });
    expect(response.status).toBe(403);
    // built-in origin-check catches before our hook — the code may be
    // INVALID_CALLBACK_URL or MAGIC_LINK_CALLBACK_FORBIDDEN depending on
    // execution order, but delivery must never fire.
    const parsed = errorBodyShape.parse(body);
    expect(
      parsed.code === 'INVALID_CALLBACK_URL' || parsed.code === 'MAGIC_LINK_CALLBACK_FORBIDDEN',
    ).toBe(true);
    expect(delivery.callCount()).toBe(0);
  });

  test('http scheme → 403 (layer 1: downgrade attempt, scheme not in trustedOrigins)', async () => {
    const { response } = await post({
      email: 'reject-http@example.com',
      callbackURL: `http://${env.MAGIC_LINK_UNIVERSAL_LINK_HOST}${env.MAGIC_LINK_UNIVERSAL_LINK_PATH}`,
    });
    expect(response.status).toBe(403);
    expect(delivery.callCount()).toBe(0);
  });

  test('same host but different path → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2: our hook)', async () => {
    const evilPath = `${env.MAGIC_LINK_UNIVERSAL_LINK_PATH}/admin`;
    const { response, body } = await post({
      email: 'reject-path@example.com',
      callbackURL: `https://${env.MAGIC_LINK_UNIVERSAL_LINK_HOST}${evilPath}`,
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('trailing-slash variant on allowlisted URL → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2, byte-equal, no normalization)', async () => {
    const { response, body } = await post({
      email: 'reject-trailing@example.com',
      callbackURL: `${allowedCallbackURL}/`,
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('allowlisted URL with appended query → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2)', async () => {
    const { response, body } = await post({
      email: 'reject-extra-query@example.com',
      callbackURL: `${allowedCallbackURL}?redirect=https://evil`,
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('allowlisted URL with fragment → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2)', async () => {
    const { response, body } = await post({
      email: 'reject-fragment@example.com',
      callbackURL: `${allowedCallbackURL}#frag`,
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('userinfo-smuggled variant on allowlisted host → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2)', async () => {
    const { response, body } = await post({
      email: 'reject-userinfo@example.com',
      callbackURL: `https://attacker@${env.MAGIC_LINK_UNIVERSAL_LINK_HOST}${env.MAGIC_LINK_UNIVERSAL_LINK_PATH}`,
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('relative path → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2: built-in allows relative, ours does not)', async () => {
    // `originCheck` passes relative paths through with `allowRelativePaths: true`;
    // our hook rejects because the absolute Universal Link URL cannot be a relative path.
    const { response, body } = await post({
      email: 'reject-relative@example.com',
      callbackURL: '/sign-in',
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });

  test('empty string callbackURL → 403 MAGIC_LINK_CALLBACK_FORBIDDEN (layer 2)', async () => {
    // Empty string is a defined value, not absent — our hook treats it as
    // "submitted but not the allowlisted URL" and rejects.
    const { response, body } = await post({
      email: 'reject-empty@example.com',
      callbackURL: '',
    });
    expect(response.status).toBe(403);
    expect(errorBodyShape.parse(body).code).toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
    expect(delivery.callCount()).toBe(0);
  });
});

describe('magic-link: email validation', () => {
  test('malformed email → 400, delivery not invoked', async () => {
    const { response } = await post({ email: 'not-an-email' });
    expect(response.status).toBe(400);
    expect(delivery.callCount()).toBe(0);
  });

  test('missing email → 400', async () => {
    const { response } = await post({});
    expect(response.status).toBe(400);
    expect(delivery.callCount()).toBe(0);
  });

  test('empty email → 400', async () => {
    const { response } = await post({ email: '' });
    expect(response.status).toBe(400);
    expect(delivery.callCount()).toBe(0);
  });
});

describe('magic-link: verify round-trip', () => {
  test('valid token → 200 with session JSON, user created, email verified', async () => {
    const email = 'roundtrip@example.com';
    await clearEmail(email);
    const { response } = await post({ email });
    expect(response.status).toBe(200);
    const { token } = delivery.latest();

    const verifyResponse = await verifyViaToken(token);
    expect(verifyResponse.status).toBe(200);
    const json = verifyBodyShape.parse(await verifyResponse.json());
    expect(json.user.email).toBe(email);
    expect(json.token.length).toBeGreaterThan(0);
    // Bearer plugin mirrors the session token on a response header for
    // platforms that read it there (iOS uses this path).
    expect(verifyResponse.headers.get('set-auth-token')?.length ?? 0).toBeGreaterThan(0);

    const rows = await db.select().from(user).where(eq(user.email, email));
    expect(rows.length).toBe(1);
    expect(rows[0]?.emailVerified).toBe(true);
    await clearEmail(email);
  });

  test('unknown token → redirect with ?error=INVALID_TOKEN', async () => {
    const response = await verifyViaToken('never-issued-token');
    expect([301, 302, 303, 307, 308]).toContain(response.status);
    const location = response.headers.get('location');
    expect(location).toBeTruthy();
    expect(location ?? '').toContain('error=INVALID_TOKEN');
  });

  test('same token used twice → second attempt redirected with ATTEMPTS_EXCEEDED', async () => {
    const email = 'double-spend@example.com';
    await clearEmail(email);
    await post({ email });
    const { token } = delivery.latest();

    const first = await verifyViaToken(token);
    expect(first.status).toBe(200);

    const second = await verifyViaToken(token);
    expect([301, 302, 303, 307, 308]).toContain(second.status);
    const location = second.headers.get('location') ?? '';
    // Second attempt either hits ATTEMPTS_EXCEEDED (if verification row
    // still exists) or INVALID_TOKEN (if it was deleted). Both encode the
    // same user-visible outcome: the token is no longer usable.
    expect(/error=(?:ATTEMPTS_EXCEEDED|INVALID_TOKEN)/v.test(location)).toBe(true);
    await clearEmail(email);
  });

  test('expired token → redirect with EXPIRED_TOKEN', async () => {
    const email = 'expired@example.com';
    await clearEmail(email);
    await post({ email });
    const { token } = delivery.latest();
    const identifier = base64UrlNoPadSha256(token);

    // Forcibly age the verification row past expiry. This exercises the
    // plugin's expiry branch with the plugin's own token identifier.
    await db
      .update(verification)
      .set({ expiresAt: new Date(Date.now() - 60_000) })
      .where(eq(verification.identifier, identifier));

    const response = await verifyViaToken(token);
    expect([301, 302, 303, 307, 308]).toContain(response.status);
    expect(response.headers.get('location') ?? '').toContain('error=EXPIRED_TOKEN');
    await clearEmail(email);
  });

  test('verify with untrusted callbackURL query → 403 (plugin originCheck)', async () => {
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', 'irrelevant');
    url.searchParams.set('callbackURL', 'https://evil.example/land');
    const response = await auth.handler(new Request(url.toString(), { method: 'GET' }));
    // The originCheck middleware runs BEFORE token lookup; an untrusted
    // callbackURL short-circuits to 403 regardless of token validity.
    expect(response.status).toBe(403);
  });
});

describe('magic-link: token storage is hashed', () => {
  test('DB row identifier is SHA-256(token) base64url-no-pad, not the plaintext token', async () => {
    const email = 'hashed-storage@example.com';
    await clearEmail(email);
    await post({ email });
    const { token } = delivery.latest();

    const plaintextRows = await db
      .select({ id: verification.id })
      .from(verification)
      .where(eq(verification.identifier, token));
    expect(plaintextRows.length).toBe(0);

    const expected = base64UrlNoPadSha256(token);
    const hashedRows = await db
      .select({ id: verification.id })
      .from(verification)
      .where(eq(verification.identifier, expected));
    expect(hashedRows.length).toBe(1);
    await clearEmail(email);
  });
});

describe('magic-link: CSRF / origin handling', () => {
  test('untrusted Origin + cookie → 403', async () => {
    const { response } = await post(
      { email: 'csrf-evil@example.com' },
      { Origin: 'https://evil.example', Cookie: 'better-auth.session_token=anything' },
    );
    expect(response.status).toBe(403);
    expect(delivery.callCount()).toBe(0);
  });

  test('trusted Origin + cookie → plugin runs', async () => {
    const email = 'csrf-trusted@example.com';
    await clearEmail(email);
    const { response } = await post({ email }, { Cookie: 'better-auth.session_token=anything' });
    // Either 200 (plugin ran) or some non-origin failure — what we must
    // see is the Origin check passing (NOT 403 INVALID_ORIGIN).
    expect(response.status).not.toBe(403);
    await clearEmail(email);
  });

  test('no cookie → origin check skipped (bearer-only path)', async () => {
    const email = 'csrf-no-cookie@example.com';
    await clearEmail(email);
    const { response } = await post({ email }, { Origin: 'https://evil.example' });
    expect(response.status).not.toBe(403);
    await clearEmail(email);
  });
});

describe('magic-link: hook scope isolation', () => {
  test('social hook does NOT fire on /sign-in/magic-link (no attestation required)', async () => {
    const email = 'scope-no-attestation@example.com';
    await clearEmail(email);
    // If the social attestation hook were mis-routed, we'd get
    // ATTESTATION_REQUIRED here. The response must either succeed or
    // fail for an unrelated reason.
    const { response, body } = await post({ email });
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code ?? '').not.toBe('ATTESTATION_REQUIRED');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_INVALID');
    expect(response.status).toBe(200);
    await clearEmail(email);
  });

  test('magic-link hook does NOT fire on /sign-in/social (no callback check)', async () => {
    // Submit a /sign-in/social request with no attestation header. We
    // must see the SOCIAL hook's ATTESTATION_REQUIRED code, NOT the
    // magic-link hook's MAGIC_LINK_CALLBACK_FORBIDDEN code. That proves
    // the path dispatch in `buildBeforeHook` keeps the two concerns
    // separate.
    const socialURL = `http://localhost${AUTH_BASE_PATH}/sign-in/social`;
    const response = await auth.handler(
      new Request(socialURL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Origin: trustedOrigin },
        body: JSON.stringify({ provider: 'apple', idToken: { token: 'x', nonce: 'n' } }),
      }),
    );
    const parsed = errorBodyShape.parse(await response.json());
    expect(parsed.code).toBe('ATTESTATION_REQUIRED');
    expect(parsed.code).not.toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
  });
});
