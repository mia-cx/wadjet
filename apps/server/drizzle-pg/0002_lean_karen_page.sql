CREATE TABLE "upload_parts" (
	"upload_id" text COLLATE "C" NOT NULL,
	"number" bigint NOT NULL,
	"size" bigint NOT NULL,
	"etag" text NOT NULL,
	CONSTRAINT "upload_parts_upload_id_number_pk" PRIMARY KEY("upload_id","number")
);
--> statement-breakpoint
CREATE TABLE "uploads" (
	"id" text COLLATE "C" PRIMARY KEY NOT NULL,
	"owner" text NOT NULL,
	"blob_key" text NOT NULL,
	"storage_upload_id" text NOT NULL,
	"filename" text NOT NULL,
	"kind" text NOT NULL,
	"content_type" text NOT NULL,
	"size" bigint NOT NULL,
	"device" text,
	"part_bytes" bigint NOT NULL,
	"part_count" bigint NOT NULL,
	"idempotency_key" text,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"state" text NOT NULL,
	"file_id" text COLLATE "C"
);
--> statement-breakpoint
ALTER TABLE "files" ADD COLUMN "thumbnail_version" bigint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "files" ADD COLUMN "thumbnail_blob_key" text;--> statement-breakpoint
ALTER TABLE "files" ADD COLUMN "thumbnail_content_type" text;--> statement-breakpoint
ALTER TABLE "files" ADD COLUMN "thumbnail_size" bigint;--> statement-breakpoint
ALTER TABLE "upload_parts" ADD CONSTRAINT "upload_parts_upload_id_uploads_id_fk" FOREIGN KEY ("upload_id") REFERENCES "public"."uploads"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "uploads_owner_idempotency" ON "uploads" USING btree ("owner","idempotency_key");