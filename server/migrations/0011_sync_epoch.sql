CREATE TABLE IF NOT EXISTS sync_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  epoch TEXT NOT NULL
);

INSERT OR IGNORE INTO sync_state(id, epoch) VALUES(1, lower(hex(randomblob(16))));
