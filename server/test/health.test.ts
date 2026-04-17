import { describe, expect, test } from 'bun:test';
import { z } from 'zod';
import { handle } from '~/server.ts';

const successBodySchema = z.strictObject({
  ok: z.literal(true),
  data: z.strictObject({ status: z.string() }),
});

const errorBodySchema = z.strictObject({
  ok: z.literal(false),
  error: z.strictObject({
    code: z.string(),
    message: z.string(),
  }),
});

describe('health', () => {
  test('GET /health returns 200 with ok:true', async () => {
    const response = handle(new Request('http://localhost/health'));
    expect(response.status).toBe(200);
    const body = successBodySchema.parse(await response.json());
    expect(body.data.status).toBe('ok');
  });
});

describe('routing', () => {
  test('unknown route returns 404', async () => {
    const response = handle(new Request('http://localhost/nope'));
    expect(response.status).toBe(404);
    const body = errorBodySchema.parse(await response.json());
    expect(body.error.code).toBe('not_found');
  });

  test('wrong method returns 404', () => {
    const response = handle(new Request('http://localhost/health', { method: 'POST' }));
    expect(response.status).toBe(404);
  });
});
