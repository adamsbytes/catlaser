import type { Config } from 'drizzle-kit';
import { defineConfig } from 'drizzle-kit';
import { env } from './src/lib/env.ts';

const config: Config = defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: { url: env.DATABASE_URL },
  strict: true,
  verbose: true,
});

export default config;
