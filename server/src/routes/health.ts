import { successResponse } from '~/lib/http.ts';

export const healthRoute = (): Response => successResponse({ status: 'ok' });
