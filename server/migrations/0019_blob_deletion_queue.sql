CREATE TABLE blob_deletion_queue (
    storage_key TEXT PRIMARY KEY,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at TEXT NOT NULL,
    last_attempt_at TEXT
);

CREATE INDEX idx_blob_deletion_queue_created
    ON blob_deletion_queue(created_at, storage_key);
