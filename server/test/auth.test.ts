import { beforeAll, describe, expect, test } from 'bun:test';
import { z } from 'zod';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import { handle } from '~/server.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

const AUTH_BASE = '/api/v1/auth';

const [trustedOrigin] = env.TRUSTED_ORIGINS;
if (trustedOrigin === undefined) {
  throw new Error('env.TRUSTED_ORIGINS must contain at least one entry');
}
const untrustedOrigin = 'https://evil.example';

const sessionShape = z.object({
  user: z.unknown().nullable(),
  session: z.unknown().nullable(),
});

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

const callAuth = async (
  path: string,
  init: RequestInit = {},
): Promise<{ response: Response; body: unknown }> => {
  const url = `http://localhost${AUTH_BASE}${path}`;
  const mergedHeaders = new Headers(init.headers);
  if (!mergedHeaders.has('X-Forwarded-For')) {
    const ipHeader = uniqueClientIpHeader();
    const forwardedFor = ipHeader['X-Forwarded-For'];
    if (forwardedFor !== undefined) {
      mergedHeaders.set('X-Forwarded-For', forwardedFor);
    }
  }
  const response = await handle(new Request(url, { ...init, headers: mergedHeaders }));
  const text = await response.text();
  const body: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { response, body };
};

let device: TestDeviceKey;
let signOutHeader: string;

beforeAll(() => {
  device = createTestDeviceKey();
  signOutHeader = buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'signOut', timestamp: 1n },
  });
});

describe('auth: mounting', () => {
  test('routes mount at /api/v1/auth (ok endpoint returns 200)', async () => {
    const { response, body } = await callAuth('/ok');
    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true });
  });

  test('requests outside /api/v1/auth prefix do not reach auth handler', async () => {
    const response = await handle(new Request('http://localhost/api/auth/ok'));
    expect(response.status).toBe(404);
  });
});

describe('auth: unauthenticated session', () => {
  test('GET get-session without credentials returns null session', async () => {
    const { response, body } = await callAuth('/get-session');
    expect(response.status).toBe(200);
    if (body === null) {
      return;
    }
    const parsed = sessionShape.parse(body);
    expect(parsed.session).toBeNull();
    expect(parsed.user).toBeNull();
  });

  test('GET get-session with unsigned bearer token returns null (requireSignature enforced)', async () => {
    const { response, body } = await callAuth('/get-session', {
      headers: { Authorization: 'Bearer unsigned-garbage-token' },
    });
    expect(response.status).toBe(200);
    if (body === null) {
      return;
    }
    const parsed = sessionShape.parse(body);
    expect(parsed.session).toBeNull();
    expect(parsed.user).toBeNull();
  });

  test('GET get-session with malformed Authorization header returns null', async () => {
    const { response, body } = await callAuth('/get-session', {
      headers: { Authorization: 'not-a-bearer-scheme' },
    });
    expect(response.status).toBe(200);
    if (body === null) {
      return;
    }
    const parsed = sessionShape.parse(body);
    expect(parsed.session).toBeNull();
  });
});

describe('auth: trusted origins (CSRF protection for cookie-bearing requests)', () => {
  // Origin/CSRF enforcement only applies when the request carries a Cookie header
  // (better-auth validateOrigin short-circuits when useCookies is false — bearer
  // clients can't be CSRF'd because browsers don't auto-attach Bearer headers).
  // These tests exercise the enforcement path that protects cookie-session clients.
  //
  // Because `/sign-out` is attestation-gated, each request here attaches a
  // valid `out:` binding so the origin check is the layer exercised — the
  // alternative (no attestation) would short-circuit to 401
  // ATTESTATION_REQUIRED and leave origin behavior unverified.

  test('POST with untrusted Origin and a cookie is rejected with 403', async () => {
    const { response, body } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Origin: untrustedOrigin,
        Cookie: 'better-auth.session_token=placeholder',
        'Content-Type': 'application/json',
        [ATTESTATION_HEADER_NAME]: signOutHeader,
      },
    });
    expect(response.status).toBe(403);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.message?.toLowerCase()).toContain('origin');
  });

  test('POST with trusted Origin and a cookie passes the origin check', async () => {
    const { response } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Origin: trustedOrigin,
        Cookie: 'better-auth.session_token=placeholder',
        'Content-Type': 'application/json',
        [ATTESTATION_HEADER_NAME]: signOutHeader,
      },
    });
    // Trusted origin means the origin check passes. Without a real session the
    // handler may return 401 — what matters is it wasn't rejected as 403 origin-block.
    expect(response.status).not.toBe(403);
  });

  test('POST with a cookie but missing Origin header is rejected with 403', async () => {
    const { response } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Cookie: 'better-auth.session_token=placeholder',
        'Content-Type': 'application/json',
        [ATTESTATION_HEADER_NAME]: signOutHeader,
      },
    });
    expect(response.status).toBe(403);
  });

  test('POST without a cookie skips origin check (bearer-only clients)', async () => {
    const { response } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Origin: untrustedOrigin,
        'Content-Type': 'application/json',
        [ATTESTATION_HEADER_NAME]: signOutHeader,
      },
    });
    // Documents the bearer-only path: no cookie means no CSRF vector, so the
    // origin header is intentionally not gated. Bearer tokens are protected by
    // signature validation (requireSignature), not origin policy.
    expect(response.status).not.toBe(403);
  });
});

describe('auth: sign-out attestation gate', () => {
  test('POST /sign-out without attestation → 401 ATTESTATION_REQUIRED regardless of origin', async () => {
    const { response, body } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Origin: trustedOrigin,
        'Content-Type': 'application/json',
      },
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_REQUIRED');
  });

  test('POST /sign-out with req: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const reqHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: 1n },
    });
    const { response, body } = await callAuth('/sign-out', {
      method: 'POST',
      headers: {
        Origin: trustedOrigin,
        'Content-Type': 'application/json',
        [ATTESTATION_HEADER_NAME]: reqHeader,
      },
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_BINDING_MISMATCH');
  });
});

describe('auth: email/password disabled', () => {
  test('POST sign-in/email returns 400 with email/password-not-enabled error', async () => {
    const { response, body } = await callAuth('/sign-in/email', {
      method: 'POST',
      headers: {
        Origin: trustedOrigin,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ email: 'test@example.com', password: 'x'.repeat(12) }),
    });
    expect(response.status).toBe(400);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.message?.toLowerCase()).toContain('email and password');
  });

  test('POST sign-up/email returns 400 with email/password-not-enabled error', async () => {
    const { response, body } = await callAuth('/sign-up/email', {
      method: 'POST',
      headers: {
        Origin: trustedOrigin,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: 'test@example.com',
        password: 'x'.repeat(12),
        name: 'Test',
      }),
    });
    expect(response.status).toBe(400);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.message?.toLowerCase()).toContain('email and password');
  });
});

const tableNameRow = z.object({ table_name: z.string() });
const columnNameRow = z.object({ column_name: z.string() });

describe('auth: schema presence', () => {
  test('better-auth core tables exist in Postgres', async () => {
    const rows = z.array(tableNameRow).parse(
      await db.$client`
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name IN ('user', 'session', 'account', 'verification')
        ORDER BY table_name
      `,
    );
    const names = rows.map((row) => row.table_name);
    expect(names).toEqual(['account', 'session', 'user', 'verification']);
  });

  test('session table has token column (bearer plugin writes sessions here)', async () => {
    const rows = z.array(columnNameRow).parse(
      await db.$client`
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'session'
        ORDER BY column_name
      `,
    );
    const names = rows.map((row) => row.column_name);
    expect(names).toContain('token');
    expect(names).toContain('expires_at');
    expect(names).toContain('user_id');
  });
});
