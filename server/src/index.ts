import pino from 'pino';
import { handle } from '~/server.ts';

const isDev = process.env.NODE_ENV !== 'production';
const logger = isDev ? pino({ transport: { target: 'pino-pretty' } }) : pino();

const port = Number.parseInt(process.env['PORT'] ?? '3000', 10);

const server = Bun.serve({ port, fetch: handle });
logger.info({ port: server.port }, 'catlaser coordination server listening');
