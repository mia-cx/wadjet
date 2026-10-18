CREATE TABLE `upload_parts` (
	`upload_id` text NOT NULL,
	`number` integer NOT NULL,
	`size` integer NOT NULL,
	`etag` text NOT NULL,
	PRIMARY KEY(`upload_id`, `number`),
	FOREIGN KEY (`upload_id`) REFERENCES `uploads`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `uploads` (
	`id` text PRIMARY KEY NOT NULL,
	`owner` text NOT NULL,
	`blob_key` text NOT NULL,
	`storage_upload_id` text NOT NULL,
	`filename` text NOT NULL,
	`kind` text NOT NULL,
	`content_type` text NOT NULL,
	`size` integer NOT NULL,
	`device` text,
	`part_bytes` integer NOT NULL,
	`part_count` integer NOT NULL,
	`idempotency_key` text,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL,
	`state` text NOT NULL,
	`file_id` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `uploads_owner_idempotency` ON `uploads` (`owner`,`idempotency_key`);--> statement-breakpoint
ALTER TABLE `files` ADD `thumbnail_version` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `files` ADD `thumbnail_blob_key` text;--> statement-breakpoint
ALTER TABLE `files` ADD `thumbnail_content_type` text;--> statement-breakpoint
ALTER TABLE `files` ADD `thumbnail_size` integer;