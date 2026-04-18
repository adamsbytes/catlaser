import { createHash } from 'node:crypto';
import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { user, verification } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { resolveAllowedCallbackUrl } from '~/lib/magic-link.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the magic-link plugin plus the
 * device-attestation plugin that gates it.
 *
 * Four invariants dominate this file:
 *
 * 1. The emailed URL is ALWAYS the Universal Link URL, never the API
 *    verify endpoint and never influenced by client-supplied body fields.
 * 2. Client-submitted `callbackURL` values are allowlisted to the exact
 *    Universal Link URL; any other host, path, scheme, or relative value
 *    is rejected with 403 `MAGIC_LINK_CALLBACK_FORBIDDEN`.
 * 3. Tokens land in the `verification` table hashed (base64url-no-pad
 *    SHA-256); the wire token stays plaintext so the email is usable.
 * 4. Both `POST /sign-in/magic-link` and `GET /magic-link/verify`
 *    require a v3 device-attestation header whose binding matches
 *    the endpoint (`req:` / `ver:` respectively) and whose ECDSA
 *    signature verifies. Callers without an attestation are rejected
 *    by the attestation plugin before the magic-link plugin runs.
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
let device: TestDeviceKey;

/**
 * Default to the real wall clock so the ±60s attestation skew window
 * accepts; tests that want to drive skew failure pass an explicit
 * timestamp or use the dedicated suite in `binding-enforcement.test.ts`.
 */
const currentUnixSeconds = (): bigint => BigInt(Math.floor(Date.now() / 1000));

const reqAttestation = (timestamp: bigint = currentUnixSeconds()): string =>
  buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'request', timestamp },
  });

const verAttestation = (token: string): string =>
  buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'verify', token },
  });

interface PostOptions {
  /** Explicit attestation header to attach; defaults to a valid `req:`
   * binding signed with the shared test device key. */
  readonly attestation?: string;
  /** Set to true to omit the attestation header entirely — used to
   * exercise the ATTESTATION_REQUIRED rejection path. */
  readonly skipAttestation?: boolean;
}

const post = async (
  body: unknown,
  extraHeaders: Record<string, string> = {},
  options: PostOptions = {},
): Promise<{ response: Response; body: unknown }> => {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Origin: trustedOrigin,
    ...uniqueClientIpHeader(),
    ...extraHeaders,
  };
  if (options.skipAttestation !== true) {
    headers[ATTESTATION_HEADER_NAME] = options.attestation ?? reqAttestation();
  }
  const init: RequestInit = {
    method: 'POST',
    headers,
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
  const headers: Record<string, string> = {
    [ATTESTATION_HEADER_NAME]: verAttestation(token),
    ...uniqueClientIpHeader(),
  };
  return await auth.handler(new Request(url.toString(), { method: 'GET', headers }));
};

const verifyRaw = async (
  token: string,
  headers: Record<string, string> = {},
): Promise<Response> => {
  const url = new URL(VERIFY_URL_BASE);
  url.searchParams.set('token', token);
  const fullHeaders: Record<string, string> = { ...uniqueClientIpHeader(), ...headers };
  return await auth.handler(new Request(url.toString(), { method: 'GET', headers: fullHeaders }));
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
  device = createTestDeviceKey();
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
  // The callback-URL allowlist check lives in `options.hooks.before`,
  // which better-auth runs before plugin hooks. With that ordering, a
  // malformed `callbackURL` is refused before the attestation plugin
  // ever parses the header — so these tests submit an attestation, but
  // the response code is driven by the callback-URL layer.
  //
  //  - better-auth's built-in `originCheckMiddleware` catches the
  //    "scheme/host not trusted" class with `INVALID_CALLBACK_URL` / 403.
  //  - Our `buildBeforeHook` in `auth-hooks.ts` catches the "host is
  //    trusted but path / shape is wrong" class with
  //    `MAGIC_LINK_CALLBACK_FORBIDDEN` / 403.
  //
  // Either way, `sendMagicLink` must not fire and `delivery.callCount()`
  // must stay zero — that is the real phishing-relay invariant.

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

describe('magic-link: attestation enforcement on both endpoints', () => {
  test('POST /sign-in/magic-link without attestation → 401 ATTESTATION_REQUIRED, delivery not invoked', async () => {
    const { response, body } = await post(
      { email: 'no-attestation@example.com' },
      {},
      { skipAttestation: true },
    );
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_REQUIRED');
    expect(delivery.callCount()).toBe(0);
  });

  test('GET /magic-link/verify without attestation → 401 ATTESTATION_REQUIRED', async () => {
    const response = await verifyRaw('anything');
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(await response.json());
    expect(parsed.code).toBe('ATTESTATION_REQUIRED');
  });

  test('POST /sign-in/magic-link with a sis: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const misboundHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: {
        tag: 'social',
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        rawNonce: 'oops',
      },
    });
    const { response, body } = await post(
      { email: 'wrong-tag@example.com' },
      {},
      { attestation: misboundHeader },
    );
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_BINDING_MISMATCH');
    expect(delivery.callCount()).toBe(0);
  });

  test('GET /magic-link/verify with a req: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const misboundHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: 1n },
    });
    const response = await verifyRaw('any-token', { [ATTESTATION_HEADER_NAME]: misboundHeader });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(await response.json());
    expect(parsed.code).toBe('ATTESTATION_BINDING_MISMATCH');
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

  test('unknown token → 401 DEVICE_MISMATCH (stored-device-match rejects before plugin runs)', async () => {
    // The crypto floor alone would accept the signature and hand the
    // request to the magic-link plugin, which would then redirect with
    // `?error=INVALID_TOKEN`. The stored-device match short-circuits
    // with `DEVICE_MISMATCH` because the magic-link attestation table
    // has no row under this token's identifier — the plugin's
    // INVALID_TOKEN redirect is unreachable without a valid stored
    // attestation.
    const response = await verifyViaToken('never-issued-token');
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(await response.json());
    expect(parsed.code).toBe('DEVICE_MISMATCH');
  });

  test('same token used twice → second attempt rejected with DEVICE_MISMATCH', async () => {
    // After a successful verify, the stored `magic_link_attestation`
    // row is deleted (the binding's purpose is spent, and the session
    // attestation now holds the per-session SE pk directly). A replay
    // therefore fails the stored-device match before the magic-link
    // plugin's own double-spend gate can run. That is the correct
    // refusal mode under the v4 contract: DEVICE_MISMATCH, not an
    // ATTEMPTS_EXCEEDED redirect. The underlying double-spend guarantee
    // remains intact — the same token cannot be redeemed a second time.
    const email = 'double-spend@example.com';
    await clearEmail(email);
    await post({ email });
    const { token } = delivery.latest();

    const first = await verifyViaToken(token);
    expect(first.status).toBe(200);

    const second = await verifyViaToken(token);
    expect(second.status).toBe(401);
    const parsed = errorBodyShape.parse(await second.json());
    expect(parsed.code).toBe('DEVICE_MISMATCH');
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

  test('verify with untrusted callbackURL query → 403 (plugin originCheck, after stored-device match)', async () => {
    // The ver: binding must byte-match a stored attestation before the
    // plugin's originCheck middleware even runs. Issue a real magic link
    // first so the stored row exists; then attempt the verify with a bad
    // callbackURL. That way the originCheck rejection (403) is what this
    // test is actually observing, not a trivial DEVICE_MISMATCH from a
    // fabricated token.
    const email = 'untrusted-cb@example.com';
    await clearEmail(email);
    await post({ email });
    const { token } = delivery.latest();

    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', token);
    url.searchParams.set('callbackURL', 'https://evil.example/land');
    const response = await auth.handler(
      new Request(url.toString(), {
        method: 'GET',
        headers: { [ATTESTATION_HEADER_NAME]: verAttestation(token), ...uniqueClientIpHeader() },
      }),
    );
    expect(response.status).toBe(403);
    await clearEmail(email);
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

describe('magic-link: plugin scope isolation', () => {
  test('callback-URL hook does NOT fire on /sign-in/social', async () => {
    // POST /sign-in/social with no attestation header. The magic-link
    // callback-URL hook's MAGIC_LINK_CALLBACK_FORBIDDEN code must NOT
    // appear; the attestation plugin is the layer that rejects.
    const socialURL = `http://localhost${AUTH_BASE_PATH}/sign-in/social`;
    const response = await auth.handler(
      new Request(socialURL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({ provider: 'apple', idToken: { token: 'x', nonce: 'n' } }),
      }),
    );
    const parsed = errorBodyShape.parse(await response.json());
    expect(parsed.code).toBe('ATTESTATION_REQUIRED');
    expect(parsed.code).not.toBe('MAGIC_LINK_CALLBACK_FORBIDDEN');
  });

  test('attestation req: binding on /sign-in/magic-link passes through to the magic-link plugin', async () => {
    const email = 'scope-req-binding@example.com';
    await clearEmail(email);
    const { response, body } = await post({ email });
    const parsed = errorBodyShape.parse(body);
    // No attestation code fires when the header, tag, and signature are
    // valid. The magic-link plugin then runs and emits the email.
    expect(parsed.code ?? '').not.toContain('ATTESTATION_');
    expect(response.status).toBe(200);
    expect(delivery.callCount()).toBe(1);
    await clearEmail(email);
  });
});
