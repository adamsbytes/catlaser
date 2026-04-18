CREATE TABLE "account" (
	"id" text PRIMARY KEY NOT NULL,
	"account_id" text NOT NULL,
	"provider_id" text NOT NULL,
	"user_id" text NOT NULL,
	"access_token" text,
	"refresh_token" text,
	"id_token" text,
	"access_token_expires_at" timestamp,
	"refresh_token_expires_at" timestamp,
	"scope" text,
	"password" text,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
CREATE TABLE "device" (
	"id" text PRIMARY KEY NOT NULL,
	"slug" text NOT NULL,
	"public_key_ed25519" text NOT NULL,
	"tailscale_host" text NOT NULL,
	"tailscale_port" integer NOT NULL,
	"device_name" text,
	"registered_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "device_slug_unique" UNIQUE("slug")
);
--> statement-breakpoint
CREATE TABLE "device_access_grant" (
	"id" text PRIMARY KEY NOT NULL,
	"device_slug" text NOT NULL,
	"user_spki_b64" text NOT NULL,
	"user_id" text,
	"granted_at" timestamp NOT NULL,
	"revoked_at" timestamp,
	"revision" bigint NOT NULL,
	CONSTRAINT "device_access_grant_device_user_unique" UNIQUE("device_slug","user_spki_b64")
);
--> statement-breakpoint
CREATE TABLE "device_acl_revision" (
	"device_slug" text PRIMARY KEY NOT NULL,
	"revision" bigint NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
CREATE TABLE "device_pairing_code" (
	"id" text PRIMARY KEY NOT NULL,
	"code_hash" text NOT NULL,
	"device_id" text NOT NULL,
	"device_name" text,
	"tailscale_host" text NOT NULL,
	"tailscale_port" integer NOT NULL,
	"expires_at" timestamp NOT NULL,
	"claimed_at" timestamp,
	"claimed_by_user_id" text,
	"revoked_at" timestamp,
	"created_at" timestamp NOT NULL,
	CONSTRAINT "device_pairing_code_code_hash_unique" UNIQUE("code_hash")
);
--> statement-breakpoint
CREATE TABLE "email_rate_limit" (
	"id" text PRIMARY KEY NOT NULL,
	"email_hash" text NOT NULL,
	"window_started_at" timestamp NOT NULL,
	"request_count" integer NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "email_rate_limit_email_hash_unique" UNIQUE("email_hash")
);
--> statement-breakpoint
CREATE TABLE "idempotency_record" (
	"id" text PRIMARY KEY NOT NULL,
	"session_id" text NOT NULL,
	"idempotency_key" text NOT NULL,
	"request_hash" text NOT NULL,
	"status_code" integer,
	"response_body" text,
	"response_content_type" text,
	"created_at" timestamp NOT NULL,
	"expires_at" timestamp NOT NULL,
	CONSTRAINT "idempotency_record_session_key_unique" UNIQUE("session_id","idempotency_key")
);
--> statement-breakpoint
CREATE TABLE "magic_link_attestation" (
	"id" text PRIMARY KEY NOT NULL,
	"token_identifier" text NOT NULL,
	"fingerprint_hash" text NOT NULL,
	"public_key_spki" text NOT NULL,
	"expires_at" timestamp NOT NULL,
	"created_at" timestamp NOT NULL,
	CONSTRAINT "magic_link_attestation_token_identifier_unique" UNIQUE("token_identifier")
);
--> statement-breakpoint
CREATE TABLE "rate_limit" (
	"id" text PRIMARY KEY NOT NULL,
	"key" text NOT NULL,
	"count" integer NOT NULL,
	"last_request" bigint NOT NULL,
	CONSTRAINT "rate_limit_key_unique" UNIQUE("key")
);
--> statement-breakpoint
CREATE TABLE "session" (
	"id" text PRIMARY KEY NOT NULL,
	"expires_at" timestamp NOT NULL,
	"token" text NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	"ip_address" text,
	"user_agent" text,
	"user_id" text NOT NULL,
	CONSTRAINT "session_token_unique" UNIQUE("token")
);
--> statement-breakpoint
CREATE TABLE "session_attestation" (
	"id" text PRIMARY KEY NOT NULL,
	"session_id" text NOT NULL,
	"fingerprint_hash" text NOT NULL,
	"public_key_spki" text NOT NULL,
	"created_at" timestamp NOT NULL,
	CONSTRAINT "session_attestation_session_id_unique" UNIQUE("session_id")
);
--> statement-breakpoint
CREATE TABLE "user" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"email" text NOT NULL,
	"email_verified" boolean DEFAULT false NOT NULL,
	"image" text,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "user_email_unique" UNIQUE("email")
);
--> statement-breakpoint
CREATE TABLE "verification" (
	"id" text PRIMARY KEY NOT NULL,
	"identifier" text NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
ALTER TABLE "account" ADD CONSTRAINT "account_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "device_access_grant" ADD CONSTRAINT "device_access_grant_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "device_pairing_code" ADD CONSTRAINT "device_pairing_code_claimed_by_user_id_user_id_fk" FOREIGN KEY ("claimed_by_user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "idempotency_record" ADD CONSTRAINT "idempotency_record_session_id_session_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."session"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "session" ADD CONSTRAINT "session_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "session_attestation" ADD CONSTRAINT "session_attestation_session_id_session_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."session"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "account_userId_idx" ON "account" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "device_slug_idx" ON "device" USING btree ("slug");--> statement-breakpoint
CREATE INDEX "device_access_grant_device_slug_active_idx" ON "device_access_grant" USING btree ("device_slug","revoked_at");--> statement-breakpoint
CREATE INDEX "device_access_grant_device_slug_revision_idx" ON "device_access_grant" USING btree ("device_slug","revision");--> statement-breakpoint
CREATE INDEX "device_pairing_code_expires_at_idx" ON "device_pairing_code" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "device_pairing_code_device_id_idx" ON "device_pairing_code" USING btree ("device_id");--> statement-breakpoint
CREATE INDEX "device_pairing_code_claimed_by_user_id_idx" ON "device_pairing_code" USING btree ("claimed_by_user_id");--> statement-breakpoint
CREATE INDEX "device_pairing_code_user_active_idx" ON "device_pairing_code" USING btree ("claimed_by_user_id","revoked_at","claimed_at");--> statement-breakpoint
CREATE INDEX "email_rate_limit_window_started_at_idx" ON "email_rate_limit" USING btree ("window_started_at");--> statement-breakpoint
CREATE INDEX "idempotency_record_session_id_idx" ON "idempotency_record" USING btree ("session_id");--> statement-breakpoint
CREATE INDEX "idempotency_record_expires_at_idx" ON "idempotency_record" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "magic_link_attestation_expires_at_idx" ON "magic_link_attestation" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "session_userId_idx" ON "session" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "session_attestation_session_id_idx" ON "session_attestation" USING btree ("session_id");--> statement-breakpoint
CREATE INDEX "verification_identifier_idx" ON "verification" USING btree ("identifier");