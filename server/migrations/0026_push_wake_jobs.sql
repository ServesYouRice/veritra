CREATE TABLE push_wake_jobs (
    sync_event_id INTEGER NOT NULL REFERENCES sync_events(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    recipient_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    subscription_id TEXT NOT NULL REFERENCES push_subscriptions(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    next_attempt_at TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_token TEXT,
    lease_expires_at TEXT,
    expires_at TEXT NOT NULL,
    PRIMARY KEY (sync_event_id, recipient_account_id, subscription_id)
);

CREATE INDEX idx_push_wake_jobs_claim
    ON push_wake_jobs(next_attempt_at, lease_expires_at, expires_at, sync_event_id);

CREATE INDEX idx_push_wake_jobs_subscription
    ON push_wake_jobs(subscription_id);
