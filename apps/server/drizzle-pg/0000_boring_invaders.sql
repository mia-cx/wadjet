CREATE TABLE "files" (
	"id" text COLLATE "C" PRIMARY KEY NOT NULL,
	"owner" text NOT NULL,
	"filename" text NOT NULL,
	"extension" text,
	"kind" text NOT NULL,
	"content_type" text NOT NULL,
	"size" bigint NOT NULL,
	"device" text,
	"created_at" timestamp with time zone NOT NULL,
	"blob_key" text NOT NULL,
	"delete_token_hash" text NOT NULL,
	"idempotency_key" text
);
--> statement-breakpoint
CREATE UNIQUE INDEX "files_owner_idempotency" ON "files" USING btree ("owner","idempotency_key");--> statement-breakpoint
CREATE INDEX "files_owner_created" ON "files" USING btree ("owner","created_at","id");