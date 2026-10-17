CREATE TABLE `files` (
	`id` text PRIMARY KEY NOT NULL,
	`owner` text NOT NULL,
	`filename` text NOT NULL,
	`extension` text,
	`kind` text NOT NULL,
	`content_type` text NOT NULL,
	`size` integer NOT NULL,
	`device` text,
	`created_at` integer NOT NULL,
	`blob_key` text NOT NULL,
	`delete_token_hash` text NOT NULL,
	`idempotency_key` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `files_owner_idempotency` ON `files` (`owner`,`idempotency_key`);--> statement-breakpoint
CREATE INDEX `files_owner_created` ON `files` (`owner`,`created_at`,`id`);