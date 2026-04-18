import { AUTH_BASE_PATH } from '~/lib/auth.ts';
import { env } from '~/lib/env.ts';
import { errorResponse } from '~/lib/http.ts';
import { APPLE_APP_SITE_ASSOCIATION_PATH } from '~/lib/universal-link.ts';
import { authRoute } from '~/routes/auth.ts';
import { healthRoute } from '~/routes/health.ts';
import { appleAppSiteAssociationRoute, universalLinkRoute } from '~/routes/universal-link.ts';

/**
 * Top-level dispatch. Routes are checked in a specific order because the
 * Universal Link path and the AASA path carry their own method-handling
 * contracts (GET/HEAD), and those must win over the generic 404 branch even
 * for non-GET methods so callers see a 405 with an `Allow` header rather
 * than a misleading 404. The auth prefix is structurally disjoint from both
 * (it lives under `/api/v1/auth` — enforced by env validation) so ordering
 * between blocks is safe.
 */
export const handle = async (request: Request): Promise<Response> => {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/health') {
    return healthRoute();
  }
  if (url.pathname === APPLE_APP_SITE_ASSOCIATION_PATH) {
    return appleAppSiteAssociationRoute(request);
  }
  if (url.pathname === env.MAGIC_LINK_UNIVERSAL_LINK_PATH) {
    return universalLinkRoute(request);
  }
  if (url.pathname === AUTH_BASE_PATH || url.pathname.startsWith(`${AUTH_BASE_PATH}/`)) {
    return await authRoute(request);
  }
  return errorResponse('not_found', `No route for ${request.method} ${url.pathname}`, 404);
};
