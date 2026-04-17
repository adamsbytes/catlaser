import { auth } from '~/lib/auth.ts';

export const authRoute = async (request: Request): Promise<Response> => await auth.handler(request);
