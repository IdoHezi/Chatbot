-- Stage 1: final checkpoint schema for langgraph-checkpoint-postgres 3.2.1.
-- Applied migration version: 20261125140713 (langgraph_checkpoint_postgres_3_2_1).
-- Set the application's PostgreSQL search_path to inventory_checkpoints and do not call setup().
-- Indexes are created non-concurrently because this migration is applied as DDL;
-- their names and indexed columns match the package's version-8 migration state.

CREATE SCHEMA inventory_checkpoints;
REVOKE ALL ON SCHEMA inventory_checkpoints FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE, CREATE ON SCHEMA inventory_checkpoints TO postgres;

CREATE TABLE inventory_checkpoints.checkpoint_migrations (
    v integer PRIMARY KEY
);

CREATE TABLE inventory_checkpoints.checkpoints (
    thread_id text NOT NULL,
    checkpoint_ns text NOT NULL DEFAULT '',
    checkpoint_id text NOT NULL,
    parent_checkpoint_id text,
    type text,
    checkpoint jsonb NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}',
    PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id)
);

CREATE TABLE inventory_checkpoints.checkpoint_blobs (
    thread_id text NOT NULL,
    checkpoint_ns text NOT NULL DEFAULT '',
    channel text NOT NULL,
    version text NOT NULL,
    type text NOT NULL,
    blob bytea,
    PRIMARY KEY (thread_id, checkpoint_ns, channel, version)
);

CREATE TABLE inventory_checkpoints.checkpoint_writes (
    thread_id text NOT NULL,
    checkpoint_ns text NOT NULL DEFAULT '',
    checkpoint_id text NOT NULL,
    task_id text NOT NULL,
    idx integer NOT NULL,
    channel text NOT NULL,
    type text,
    blob bytea NOT NULL,
    task_path text NOT NULL DEFAULT '',
    PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id, task_id, idx)
);

-- The package's historical migration 4 relaxes this column; the final DDL
-- already reflects that state. Migration 5 was a no-op. Migrations 6-8 add
-- these indexes and task_path. The marker at 8 prevents runtime auto-DDL.
CREATE INDEX checkpoints_thread_id_idx
    ON inventory_checkpoints.checkpoints (thread_id);
CREATE INDEX checkpoint_blobs_thread_id_idx
    ON inventory_checkpoints.checkpoint_blobs (thread_id);
CREATE INDEX checkpoint_writes_thread_id_idx
    ON inventory_checkpoints.checkpoint_writes (thread_id);

INSERT INTO inventory_checkpoints.checkpoint_migrations (v) VALUES (8);

ALTER TABLE inventory_checkpoints.checkpoint_migrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_checkpoints.checkpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_checkpoints.checkpoint_blobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_checkpoints.checkpoint_writes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES IN SCHEMA inventory_checkpoints
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA inventory_checkpoints
    FROM PUBLIC, anon, authenticated, service_role;
