import { migrate } from 'drizzle-orm/bun-sql/migrator';
import { db } from '~/lib/db.ts';

await migrate(db, { migrationsFolder: './drizzle' });
