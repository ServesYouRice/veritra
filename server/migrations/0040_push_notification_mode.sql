ALTER TABLE push_subscriptions ADD COLUMN notification_mode TEXT NOT NULL
 DEFAULT 'legacy_generic' CHECK(notification_mode IN ('legacy_generic','local_decrypt_v1'));
