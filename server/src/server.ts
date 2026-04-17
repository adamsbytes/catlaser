import { AUTH_BASE_PATH } from '~/lib/auth.ts';
import { errorResponse } from '~/lib/http.ts';
import { authRoute } from '~/routes/auth.ts';
import { healthRoute } from '~/routes/health.ts';

export const handle = async (request: Request): Promise<Response> => {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/health') {
    return healthRoute();
  }
  if (url.pathname === AUTH_BASE_PATH || url.pathname.startsWith(`${AUTH_BASE_PATH}/`)) {
    return await authRoute(request);
  }
  return errorResponse('not_found', `No route for ${request.method} ${url.pathname}`, 404);
};
