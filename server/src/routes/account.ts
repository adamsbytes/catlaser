import { auth } from '~/lib/auth.ts';
import { deleteUserAccount } from '~/lib/account-deletion.ts';
import { errorResponse, successResponse } from '~/lib/http.ts';
import type { AttestedRouteHandler, RequireAttestedSessionOptions } from '~/lib/protected-route.ts';
import { withDeleteAccountAttestedSession } from '~/lib/protected-route.ts';

/**
 * `POST /api/v1/me/delete` — permanent account deletion.
 *
 * Gated by ``withDeleteAccountAttestedSession``: the caller must
 * present a bearer token AND a fresh ``x-device-attestation`` header
 * whose binding tag is `del:`. The dedicated tag is load-bearing —
 * any other captured signature (including a routine `api:` from a
 * GET /me within the 60s skew window) is refused here. A leaked
 * bearer alone cannot delete the account; a Secure-Enclave signature
 * under the same key that signed in is also required.
 *
 * The handler defers all row deletion to
 * ``deleteUserAccount(...)``, which runs one transaction that:
 * revokes every device ACL grant owned by the user, bumps each
 * affected device's per-slug revision counter, and then drops the
 * `user` row (cascading to sessions, accounts, session-attestation,
 * and idempotency records).
 *
 * Wire contract:
 *
 * ```
 * POST /api/v1/me/delete
 * Authorization: Bearer <session bearer>
 * x-device-attestation: <del:<ts> signed payload>
 *
 * 200 OK, application/json:
 * { "deleted": true }
 * ```
 *
 * `405` with `Allow: POST` on any other method so monitoring probes
 * get a deterministic rejection rather than a generic 404.
 */

export const ACCOUNT_DELETE_PATH = '/api/v1/me/delete';

const deleteHandler: AttestedRouteHandler = async (_request, session) => {
  await deleteUserAccount({ userId: session.user.id });
  return successResponse({ deleted: true });
};

const DELETE_ALLOWED_METHODS = ['POST'] as const;

const deleteMethodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed on ${ACCOUNT_DELETE_PATH}; accepted methods are ${DELETE_ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', DELETE_ALLOWED_METHODS.join(', '));
  return response;
};

/**
 * Compose the delete-account route against a specific auth instance
 * and optional clock override. Matches the pattern on
 * ``buildDevicesPairRoute`` / ``buildDevicesPairedRoute`` so tests
 * can frame-freeze the clock and swap in a ``createAuth`` fixture
 * without touching the module-level singleton.
 */
export const buildAccountDeleteRoute = (
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  const guarded = withDeleteAccountAttestedSession(deleteHandler, options);
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') {
      return deleteMethodNotAllowed(request.method);
    }
    return await guarded(request);
  };
};

export const accountDeleteRoute = buildAccountDeleteRoute({ auth });
