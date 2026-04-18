import { SQL } from 'bun';
import { drizzle } from 'drizzle-orm/bun-sql';
import {
  account,
  accountRelations,
  devicePairingCode,
  devicePairingCodeRelations,
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
  devicePairingCode,
  userRelations,
  sessionRelations,
  accountRelations,
  sessionAttestationRelations,
  idempotencyRecordRelations,
  devicePairingCodeRelations,
};

const client: SQL = new SQL(env.DATABASE_URL);

export const db: ReturnType<typeof drizzle<typeof schema, SQL>> = drizzle({
  client,
  schema,
});

export type Database = typeof db;
