import { SQL } from 'bun';
import { drizzle } from 'drizzle-orm/bun-sql';
import {
  account,
  accountRelations,
  emailRateLimit,
  idempotencyRecord,
  idempotencyRecordRelations,
  magicLinkAttestation,
  rateLimit,
  session,
  sessionAttestation,
  sessionAttestationRelations,
  sessionRelations,
  user,
  userRelations,
  verification,
} from '~/db/schema.ts';
import { env } from '~/lib/env.ts';

const schema = {
  user,
  session,
  account,
  verification,
  magicLinkAttestation,
  sessionAttestation,
  idempotencyRecord,
  emailRateLimit,
  rateLimit,
  userRelations,
  sessionRelations,
  accountRelations,
  sessionAttestationRelations,
  idempotencyRecordRelations,
};

const client: SQL = new SQL(env.DATABASE_URL);

export const db: ReturnType<typeof drizzle<typeof schema, SQL>> = drizzle({
  client,
  schema,
});

export type Database = typeof db;
