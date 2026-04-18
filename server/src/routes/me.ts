import { auth } from '~/lib/auth.ts';
import { errorResponse, successResponse } from '~/lib/http.ts';
import { withAttestedSession } from '~/lib/protected-route.ts';

/**
 * `GET /api/v1/me` — the canonical protected-route smoke endpoint.
 *
 * Returns the authenticated user's identity (id + email + email
 * verification status). Exists as the first concrete consumer of
 * `withAttestedSession`, so any regression in the protected-route gate
 * surfaces on this endpoint long before it can be shadowed by a route
 * that also does interesting work.
 *
 * The iOS `SignedHTTPClient` targets this endpoint as its integration
 * smoke test: a fresh SE-signed `api:` attestation plus a valid bearer
 * returns 200 with the user row; any failure mode — expired bearer,
 * missing attestation, wrong binding tag, signature under the wrong
 * key, skew out of window — surfaces as one of the machine-readable
 * codes documented in `protected-route.ts`.
 *
 * POST/other methods are not supported on this resource; we return 405
 * with an `Allow: GET` header so monitoring probes get a deterministic
 * rejection rather than a generic 404.
 */

export const ME_PATH = '/api/v1/me';

const meHandler = withAttestedSession(
  (_request, session) =>
    successResponse({
      id: session.user.id,
      email: session.user.email,
      emailVerified: session.user.emailVerified,
    }),
  { auth },
);

const ALLOWED_METHODS = ['GET'] as const;

const methodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed on ${ME_PATH}; accepted methods are ${ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', ALLOWED_METHODS.join(', '));
  return response;
};

export const meRoute = async (request: Request): Promise<Response> => {
  if (request.method !== 'GET') {
    return methodNotAllowed(request.method);
  }
  return await meHandler(request);
};
