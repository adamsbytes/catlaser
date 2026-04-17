import { errorResponse } from '~/lib/http.ts';
import { healthRoute } from '~/routes/health.ts';

export const handle = (request: Request): Response => {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/health') {
    return healthRoute();
  }
  return errorResponse('not_found', `No route for ${request.method} ${url.pathname}`, 404);
};
