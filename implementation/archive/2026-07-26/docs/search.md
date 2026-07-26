# Search

Message-content search is local-client only for v1. The server must not build or store a message-content index because it never receives plaintext.

Allowed server search:

- usernames
- community names
- channel names
- other user-visible labels that are not message bodies or attachment contents

Server metadata search supports small-page `limit`/`offset` pagination and ranks exact matches before prefix matches. Account usernames only match exact case-insensitive queries. The query does not touch message envelope ciphertext, attachment blobs, reactions, or backup data.

Future work may add a client-side encrypted search index synced between a user's own devices.
