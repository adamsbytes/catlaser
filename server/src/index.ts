import pino from 'pino';
import { env } from '~/lib/env.ts';
import { handle } from '~/server.ts';

const isDev = env.NODE_ENV !== 'production';
const logger = isDev ? pino({ transport: { target: 'pino-pretty' } }) : pino();

const server = Bun.serve({ port: env.PORT, fetch: handle });
logger.info({ port: server.port }, 'catlaser coordination server listening');
