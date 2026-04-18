import { env } from '~/lib/env.ts';
import { emptyBodyResponse, errorResponse, htmlResponse, rawJsonResponse } from '~/lib/http.ts';
import {
  AASA_CACHE_HEADERS,
  buildAppleAppSiteAssociation,
  INERT_HTML_BODY,
  INERT_HTML_SECURITY_HEADERS,
} from '~/lib/universal-link.ts';

/**
 * Universal Link request handlers.
 *
 * Two routes live here — both are open, cacheable public assets and neither
 * participates in authentication. Keeping them together clarifies that
 * neither one sees, emits, or validates any authentication material.
 */

/**
 * Methods accepted on both the inert HTML and the AASA endpoints. Apple's
 * `swcd` uses GET; browsers fall back to GET for taps. HEAD is allowed
 * because monitoring and link-preview fetchers probe with HEAD and returning
 * 200 keeps them from retrying.
 */
const ALLOWED_METHODS = Object.freeze(['GET', 'HEAD'] as const);
type AllowedMethod = (typeof ALLOWED_METHODS)[number];

const isAllowedMethod = (method: string): method is AllowedMethod =>
  (ALLOWED_METHODS as readonly string[]).includes(method);

const methodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed; accepted methods are ${ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', ALLOWED_METHODS.join(', '));
  return response;
};

const asHeadIfRequested = (method: AllowedMethod, response: Response): Response =>
  method === 'HEAD' ? emptyBodyResponse(response) : response;

/**
 * Pre-build the AASA body at module load. The document is a function of
 * `Env` values validated at process-start and never changes across a
 * process's lifetime; serialising once saves work and ensures every response
 * is byte-identical.
 */
const AASA_BODY = buildAppleAppSiteAssociation(env);

/**
 * `GET /.well-known/apple-app-site-association` — publishes the AASA file so
 * iOS associates the configured Universal Link path with the app's bundle.
 * `swcd` requires `application/json`; we also emit `nosniff` so the file is
 * never reinterpreted as HTML by a misbehaving intermediate.
 */
export const appleAppSiteAssociationRoute = (request: Request): Response => {
  if (!isAllowedMethod(request.method)) {
    return methodNotAllowed(request.method);
  }
  return asHeadIfRequested(request.method, rawJsonResponse(AASA_BODY, AASA_CACHE_HEADERS));
};

/**
 * `GET <MAGIC_LINK_UNIVERSAL_LINK_PATH>` — inert HTML fallback. A browser
 * that arrives here carries a `?token=<value>` query that the server MUST
 * NOT consume: token redemption is gated by device attestation and only the
 * app can produce it. This route never reads the query string and never
 * touches the authentication handler.
 */
export const universalLinkRoute = (request: Request): Response => {
  if (!isAllowedMethod(request.method)) {
    return methodNotAllowed(request.method);
  }
  return asHeadIfRequested(
    request.method,
    htmlResponse(INERT_HTML_BODY, INERT_HTML_SECURITY_HEADERS),
  );
};
