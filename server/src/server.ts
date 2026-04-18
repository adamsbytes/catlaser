import { AUTH_BASE_PATH } from '~/lib/auth.ts';
import { env } from '~/lib/env.ts';
import { errorResponse } from '~/lib/http.ts';
import { APPLE_APP_SITE_ASSOCIATION_PATH } from '~/lib/universal-link.ts';
import { authRoute } from '~/routes/auth.ts';
import {
  DEVICES_PAIR_PATH,
  DEVICES_PAIRED_PATH,
  DEVICES_PROVISION_PATH,
  devicesAclRoute,
  devicesPairRoute,
  devicesPairedRoute,
  devicesPairingCodeRoute,
  devicesProvisionRoute,
  matchDynamicDeviceRoute,
} from '~/routes/devices.ts';
import { healthRoute } from '~/routes/health.ts';
import { ME_PATH, meRoute } from '~/routes/me.ts';
import { appleAppSiteAssociationRoute, universalLinkRoute } from '~/routes/universal-link.ts';

/**
 * Top-level dispatch. Routes are checked in a specific order because the
 * Universal Link path and the AASA path carry their own method-handling
 * contracts (GET/HEAD), and those must win over the generic 404 branch even
 * for non-GET methods so callers see a 405 with an `Allow` header rather
 * than a misleading 404. The auth prefix is structurally disjoint from every
 * other prefix — it lives under `/api/v1/auth`, while protected API routes
 * live under `/api/v1/<resource>` with `<resource> !== 'auth'` (enforced by
 * env validation of `MAGIC_LINK_UNIVERSAL_LINK_PATH` and by route naming).
 */
/**
 * Static-path route table. Each entry pairs an exact pathname with
 * the handler to invoke when `request.url`'s pathname equals it.
 * Expressing routes as data (rather than an if-ladder) keeps the
 * dispatch function below the complexity ceiling while preserving
 * a predictable top-down match order.
 */
const STATIC_ROUTES: ReadonlyArray<{
  readonly path: string;
  readonly handler: (request: Request) => Promise<Response> | Response;
}> = [
  { path: APPLE_APP_SITE_ASSOCIATION_PATH, handler: appleAppSiteAssociationRoute },
  { path: ME_PATH, handler: meRoute },
  { path: DEVICES_PAIR_PATH, handler: devicesPairRoute },
  { path: DEVICES_PAIRED_PATH, handler: devicesPairedRoute },
  { path: DEVICES_PROVISION_PATH, handler: devicesProvisionRoute },
];

const matchPrefixedRoute = (
  pathname: string,
): ((request: Request) => Promise<Response> | Response) | null => {
  if (pathname === AUTH_BASE_PATH || pathname.startsWith(`${AUTH_BASE_PATH}/`)) {
    return authRoute;
  }
  if (pathname === env.MAGIC_LINK_UNIVERSAL_LINK_PATH) {
    return universalLinkRoute;
  }
  return null;
};

const matchDeviceDynamic = (pathname: string): ((request: Request) => Promise<Response>) | null => {
  const match = matchDynamicDeviceRoute(pathname);
  if (match === null) {
    return null;
  }
  return match.kind === 'pairing-code' ? devicesPairingCodeRoute : devicesAclRoute;
};

const matchStaticRoute = (
  pathname: string,
): ((request: Request) => Promise<Response> | Response) | null => {
  const found = STATIC_ROUTES.find((route) => route.path === pathname);
  return found?.handler ?? null;
};

export const handle = async (request: Request): Promise<Response> => {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/health') {
    return healthRoute();
  }
  const prefixed = matchPrefixedRoute(url.pathname);
  if (prefixed !== null) {
    return await prefixed(request);
  }
  const staticHandler = matchStaticRoute(url.pathname);
  if (staticHandler !== null) {
    return await staticHandler(request);
  }
  const dynamic = matchDeviceDynamic(url.pathname);
  if (dynamic !== null) {
    return await dynamic(request);
  }
  return errorResponse('not_found', `No route for ${request.method} ${url.pathname}`, 404);
};
