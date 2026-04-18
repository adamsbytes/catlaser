import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { and, eq, sql } from 'drizzle-orm';
import { idempotencyRecord } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import { errorResponse } from '~/lib/http.ts';
import type { AuthenticatedSession, RequireAttestedSessionOptions } from '~/lib/protected-route.ts';
import {
  ProtectedRouteError,
  protectedRouteErrorResponse,
  requireAttestedSession,
} from '~/lib/protected-route.ts';

/**
 * Mutating-route replay protection.
 *
 * The protected-route attestation gate pins every authenticated call to the
 * per-session Secure-Enclave key, so a captured bearer alone is inert. A
 * captured `(bearer, fresh api: attestation)` pair is still briefly
 * replayable within the ±60s attestation skew window — read replays inside
 * that window are harmless (they surface state the attacker already
 * observed), but a write replay could re-execute a mutation the user did
 * not authorise a second time. This module closes that gap by deduping
 * mutating routes on `(session_id, idempotency_key)`.
 *
 * Contract observed by the middleware:
 *
 * - Clients attach `Idempotency-Key: <uuid>` on every mutating request.
 *   Missing or malformed keys → 400 with a machine-readable code.
 * - The first request under a given `(session, key)` acquires a pending
 *   lease, runs the handler, and captures the completed response (status,
 *   body, content-type).
 * - A replay with the same `(session, key)` and byte-identical
 *   `(method, path, body)` returns the cached response; the handler is
 *   NOT re-invoked.
 * - A replay with the same key but a different request fingerprint → 422
 *   `IDEMPOTENCY_KEY_MISMATCH`. This distinguishes a legitimate retry from
 *   accidental key reuse and refuses to silently shadow a prior mutation's
 *   cached result.
 * - A concurrent duplicate that observes a pending lease → 409
 *   `IDEMPOTENCY_REQUEST_IN_PROGRESS`. The client retries once the
 *   original completes.
 * - Lease TTL is `IDEMPOTENCY_TTL_SECONDS` (10 minutes) — well beyond the
 *   60s skew window so legitimate client retries over flaky networks hit
 *   the cache, while expired rows are replaced atomically by the acquire
 *   path's `ON CONFLICT DO UPDATE … WHERE expires_at <= now` predicate.
 * - Responses with status 2xx and 4xx are cached (the mutation either
 *   happened or was deterministically rejected); 5xx responses and handler
 *   exceptions release the lease so the client can retry with the same
 *   key against a healthier backend.
 * - Rows cascade-delete with the owning session via the FK on
 *   `idempotency_record.session_id`.
 *
 * The gate runs AFTER the protected-route attestation gate. A request with
 * a bad bearer or missing / stale attestation is rejected before any
 * idempotency state is touched — the store never sees unauthenticated
 * traffic, and a rejected attestation never lands a pending lease.
 */

/**
 * HTTP header the client attaches on every mutating request. Lowercased
 * for canonical matching; `Headers.get` is case-insensitive regardless.
 */
export const IDEMPOTENCY_HEADER_NAME = 'idempotency-key';

/**
 * Lease lifetime. Chosen an order of magnitude above the 60s attestation
 * skew window so a client retrying over a flaky network still hits the
 * cache, without retaining state indefinitely. Expired rows are replaced
 * in place by the acquire path — there is no background cleanup task.
 */
export const IDEMPOTENCY_TTL_SECONDS = 600;

/**
 * Accepted format for the `Idempotency-Key` header value. ADR-006
 * mandates a client-generated UUID per mutating request; enforcing
 * canonical RFC 4122 form (8-4-4-4-12 hex, case-insensitive) surfaces a
 * misconfigured client as a stable 400 rather than letting a truncated /
 * mangled key silently key into the ledger.
 */
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iv;

export type IdempotencyCode =
  | 'IDEMPOTENCY_KEY_REQUIRED'
  | 'IDEMPOTENCY_KEY_INVALID'
  | 'IDEMPOTENCY_KEY_MISMATCH'
  | 'IDEMPOTENCY_REQUEST_IN_PROGRESS';

export type IdempotentRouteHandler = (
  request: Request,
  session: AuthenticatedSession,
) => Response | Promise<Response>;

/**
 * Outcome of an acquire attempt. `acquired` holds a fresh pending lease;
 * `replay` is a completed cached response to return; `pending` signals
 * another request already owns the lease; `mismatch` signals the caller
 * reused a key for a different request.
 */
interface ReplayRecord {
  readonly kind: 'replay';
  readonly statusCode: number;
  readonly responseBody: string;
  readonly responseContentType: string;
}

type AcquireOutcome =
  | { readonly kind: 'acquired'; readonly leaseId: string }
  | { readonly kind: 'mismatch' }
  | { readonly kind: 'pending' }
  | ReplayRecord;

const idempotencyErrorResponse = (
  code: IdempotencyCode,
  message: string,
  status: number,
): Response => errorResponse(code, message, status);

const constantTimeStringEquals = (a: string, b: string): boolean => {
  const aBytes = Buffer.from(a, 'utf8');
  const bBytes = Buffer.from(b, 'utf8');
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

/**
 * Fingerprint for a mutating request. SHA-256 over
 * `METHOD || '\n' || pathname || '\n' || body`, base64url-no-pad. The
 * newline separators are unambiguous because the method is a fixed set
 * of uppercase ASCII words, pathnames are never empty (they start with
 * '/'), and the first two components contain no `\n`. A replay with the
 * same idempotency key but any different method / path / body produces
 * a different hash and trips `IDEMPOTENCY_KEY_MISMATCH`.
 */
const computeRequestHash = (method: string, pathname: string, body: string): string =>
  createHash('sha256')
    .update(`${method.toUpperCase()}\n${pathname}\n${body}`, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/**
 * Atomic lease acquisition. Issues `INSERT … ON CONFLICT DO UPDATE …
 * WHERE expires_at <= now RETURNING` against the `(session_id,
 * idempotency_key)` unique constraint, so:
 *
 * - A missing row inserts a fresh pending lease and returns its id.
 * - An existing non-expired row fails the DO UPDATE predicate. PostgreSQL
 *   leaves the row untouched and RETURNING is empty; we then load it to
 *   distinguish pending / replay / mismatch.
 * - An existing expired row matches the DO UPDATE predicate and is
 *   overwritten in place with a fresh pending lease.
 *
 * The approach means a concurrent duplicate sees the winner's row and
 * cannot produce a second execution — either the second caller's INSERT
 * blocks on the unique constraint, resolves against a non-expired row,
 * and proceeds to the SELECT branch (pending/replay/mismatch); or the
 * row has expired and the second caller takes the lease, which is
 * correct because the first lease's own TTL has passed.
 */
const acquireOrLookup = async (input: {
  readonly sessionId: string;
  readonly idempotencyKey: string;
  readonly requestHash: string;
  readonly now: Date;
}): Promise<AcquireOutcome> => {
  const expiresAt = new Date(input.now.getTime() + IDEMPOTENCY_TTL_SECONDS * 1000);
  const id = randomUUID();

  const acquired = await db
    .insert(idempotencyRecord)
    .values({
      id,
      sessionId: input.sessionId,
      idempotencyKey: input.idempotencyKey,
      requestHash: input.requestHash,
      statusCode: null,
      responseBody: null,
      responseContentType: null,
      createdAt: input.now,
      expiresAt,
    })
    .onConflictDoUpdate({
      target: [idempotencyRecord.sessionId, idempotencyRecord.idempotencyKey],
      set: {
        id,
        requestHash: input.requestHash,
        statusCode: null,
        responseBody: null,
        responseContentType: null,
        createdAt: input.now,
        expiresAt,
      },
      setWhere: sql`${idempotencyRecord.expiresAt} <= ${input.now}`,
    })
    .returning({ id: idempotencyRecord.id });

  const acquiredRow = acquired[0];
  if (acquiredRow !== undefined) {
    return { kind: 'acquired', leaseId: acquiredRow.id };
  }

  // No row acquired — an existing non-expired row is in the way. Load it
  // to classify the outcome.
  const rows = await db
    .select({
      requestHash: idempotencyRecord.requestHash,
      statusCode: idempotencyRecord.statusCode,
      responseBody: idempotencyRecord.responseBody,
      responseContentType: idempotencyRecord.responseContentType,
    })
    .from(idempotencyRecord)
    .where(
      and(
        eq(idempotencyRecord.sessionId, input.sessionId),
        eq(idempotencyRecord.idempotencyKey, input.idempotencyKey),
      ),
    )
    .limit(1);
  const existing = rows[0];
  if (existing === undefined) {
    // Transient race: the blocking row was released (handler-thrown or
    // 5xx path releases the lease) between our INSERT and our SELECT.
    // Treat as pending — the client retries, and the next acquire
    // attempt succeeds with a clean slate.
    return { kind: 'pending' };
  }

  if (!constantTimeStringEquals(existing.requestHash, input.requestHash)) {
    return { kind: 'mismatch' };
  }

  if (
    existing.responseBody === null ||
    existing.statusCode === null ||
    existing.responseContentType === null
  ) {
    return { kind: 'pending' };
  }

  return {
    kind: 'replay',
    statusCode: existing.statusCode,
    responseBody: existing.responseBody,
    responseContentType: existing.responseContentType,
  };
};

const completeLease = async (
  leaseId: string,
  statusCode: number,
  body: string,
  contentType: string,
): Promise<void> => {
  await db
    .update(idempotencyRecord)
    .set({
      statusCode,
      responseBody: body,
      responseContentType: contentType,
    })
    .where(eq(idempotencyRecord.id, leaseId));
};

const releaseLease = async (leaseId: string): Promise<void> => {
  await db.delete(idempotencyRecord).where(eq(idempotencyRecord.id, leaseId));
};

/**
 * Responses with status in `[200, 500)` are cached. 5xx indicates the
 * mutation did not deterministically complete — releasing the lease lets
 * the client retry with the same key against a healthier backend without
 * a stale 500 poisoning every subsequent retry.
 */
const isCacheableStatus = (status: number): boolean => status >= 200 && status < 500;

const validateKeyOrReject = (rawKey: string | null): string | Response => {
  const trimmed = rawKey?.trim() ?? '';
  if (trimmed.length === 0) {
    return idempotencyErrorResponse(
      'IDEMPOTENCY_KEY_REQUIRED',
      `missing or empty ${IDEMPOTENCY_HEADER_NAME} header on mutating route`,
      400,
    );
  }
  if (!UUID_PATTERN.test(trimmed)) {
    return idempotencyErrorResponse(
      'IDEMPOTENCY_KEY_INVALID',
      `${IDEMPOTENCY_HEADER_NAME} must be an RFC 4122 UUID (36 characters, 8-4-4-4-12 hex)`,
      400,
    );
  }
  return trimmed;
};

/**
 * Reconstruct the request so the downstream handler can consume the body
 * independently of the middleware's own consumption. Reads the consumed
 * body string, constructs a fresh `Request` with the same method, URL,
 * and headers, and attaches the body only when non-empty — empty-body
 * GET/HEAD requests would reject otherwise.
 */
const reconstructRequest = (original: Request, body: string): Request =>
  new Request(original.url, {
    method: original.method,
    headers: original.headers,
    body: body.length === 0 ? undefined : body,
  });

const responseFromCached = (record: ReplayRecord): Response =>
  new Response(record.responseBody, {
    status: record.statusCode,
    headers: { 'Content-Type': record.responseContentType },
  });

/**
 * Run the composed gate against a request. Returns either a session +
 * an acquired lease (caller must complete or release), or a `Response`
 * the caller must return verbatim (attestation rejection / idempotency
 * rejection / cached replay).
 */
interface AcquiredLease {
  readonly kind: 'proceed';
  readonly session: AuthenticatedSession;
  readonly request: Request;
  readonly leaseId: string;
}
interface ShortCircuit {
  readonly kind: 'respond';
  readonly response: Response;
}
type GateOutcome = AcquiredLease | ShortCircuit;

const runGate = async (
  request: Request,
  options: RequireAttestedSessionOptions,
): Promise<GateOutcome> => {
  let session: AuthenticatedSession;
  try {
    session = await requireAttestedSession(request, options);
  } catch (error) {
    if (error instanceof ProtectedRouteError) {
      return { kind: 'respond', response: protectedRouteErrorResponse(error) };
    }
    throw error;
  }

  const keyOrResponse = validateKeyOrReject(request.headers.get(IDEMPOTENCY_HEADER_NAME));
  if (keyOrResponse instanceof Response) {
    return { kind: 'respond', response: keyOrResponse };
  }
  const idempotencyKey = keyOrResponse;

  const bodyText = await request.text();
  const url = new URL(request.url);
  const requestHash = computeRequestHash(request.method, url.pathname, bodyText);
  const now = new Date();

  const outcome = await acquireOrLookup({
    sessionId: session.session.id,
    idempotencyKey,
    requestHash,
    now,
  });

  if (outcome.kind === 'mismatch') {
    return {
      kind: 'respond',
      response: idempotencyErrorResponse(
        'IDEMPOTENCY_KEY_MISMATCH',
        `${IDEMPOTENCY_HEADER_NAME} has already been used for a different request within this session`,
        422,
      ),
    };
  }
  if (outcome.kind === 'pending') {
    return {
      kind: 'respond',
      response: idempotencyErrorResponse(
        'IDEMPOTENCY_REQUEST_IN_PROGRESS',
        `a prior request with the same ${IDEMPOTENCY_HEADER_NAME} is still in flight`,
        409,
      ),
    };
  }
  if (outcome.kind === 'replay') {
    return { kind: 'respond', response: responseFromCached(outcome) };
  }

  return {
    kind: 'proceed',
    session,
    request: reconstructRequest(request, bodyText),
    leaseId: outcome.leaseId,
  };
};

/**
 * Execute the acquired-lease branch: run the handler, then either cache
 * the response or release the lease based on the returned status. Wraps
 * handler exceptions so a thrown error releases the lease before
 * propagating — otherwise a client retry would see a stale pending
 * lease and 409 until the TTL elapsed.
 */
const runHandlerWithLease = async (
  handler: IdempotentRouteHandler,
  acquired: AcquiredLease,
): Promise<Response> => {
  let response: Response;
  try {
    response = await handler(acquired.request, acquired.session);
  } catch (error) {
    await releaseLease(acquired.leaseId);
    throw error;
  }

  if (!isCacheableStatus(response.status)) {
    await releaseLease(acquired.leaseId);
    return response;
  }

  // Tee the response body into storage, then rebuild a fresh Response
  // with byte-identical body, status, and Content-Type for the current
  // caller. The original Response is consumed by `.text()` and must not
  // be reused.
  const responseContentType = response.headers.get('Content-Type') ?? 'application/octet-stream';
  const responseBody = await response.text();
  await completeLease(acquired.leaseId, response.status, responseBody, responseContentType);
  return new Response(responseBody, {
    status: response.status,
    headers: { 'Content-Type': responseContentType },
  });
};

/**
 * Compose the protected-route attestation gate + idempotency lease
 * lifecycle onto a mutating-route handler. Use this wrapper for
 * POST/PUT/PATCH/DELETE handlers that need write-replay protection;
 * read-only routes should use `withAttestedSession` directly.
 *
 * Ordering is intentional: the attestation gate runs first, so the
 * idempotency store never sees unauthenticated or unattested traffic. A
 * rejected attestation never lands a pending lease, and a legitimate
 * request always acquires its lease under the same `session_id` the
 * bearer resolves to.
 */
export const withIdempotentAttestedSession = (
  handler: IdempotentRouteHandler,
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    const gate = await runGate(request, options);
    if (gate.kind === 'respond') {
      return gate.response;
    }
    return await runHandlerWithLease(handler, gate);
  };
};
