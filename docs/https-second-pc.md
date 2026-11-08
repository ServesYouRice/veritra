# HTTPS so a second PC can connect (W12)

The app accepts only HTTPS and has no "skip certificate check" (see
[operations.md](operations.md#tls-on-a-lan-install)). So the server needs a name
and a certificate the second PC trusts. Pick one path.

## Path A: a real certificate (easiest for the user once set up)

1. Use a name in a domain you own, e.g. `chat.example.com`.
2. Point it at the server PC's address (public DNS, or a local DNS entry).
3. Use the Compose + Caddy profile: put the name in `deploy/caddy/Caddyfile`
   (replace `messenger.example.com` and the email), set `VERITRA_IMAGE` as in
   `deploy/docker-compose.yml`, and run `docker compose --profile caddy up -d`. Caddy gets the certificate by itself.
   For a server that is not reachable from the internet, use a DNS-01 challenge
   (see operations.md, option 1); that needs a Caddy build with your DNS
   provider's plugin, which the stock image does not have.
4. On the second PC, open the Veritra app and enter `https://chat.example.com`.

Nothing to install on the second PC.

## Path B: your own certificate authority (all at home, no domain)

1. Server PC: edit the shipped `deploy/caddy/Caddyfile` in place. Change only
   the site name (for example `veritra.home.arpa`) and add one line,
   `tls internal`, inside that site block. Keep everything else: the log
   filters that keep tokens out of Caddy's logs and the security headers are
   part of it. Start it with `docker compose --profile caddy up -d`.
   Caddy creates its own CA and makes the certificate. Veritra's own rule
   (operations.md) is a DNS name: no IP addresses and no `.local` names.
2. Make the name resolve on the second PC. Add one line to
   `C:\Windows\System32\drivers\etc\hosts` (as administrator):
   `192.168.1.20  veritra.home.arpa` (use the server PC's LAN address).
3. Copy Caddy's root certificate to the second PC. It is in the Caddy data
   volume: `pki/authorities/local/root.crt`
   (`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .`).
   Copy only `root.crt`, **never** `root.key`.
4. Compare the SHA-256 fingerprint of `root.crt` on both PCs (for example
   `certutil -hashfile root.crt SHA256`); they must match. Then, on the second
   PC (Windows), as the user who runs Veritra:
   `certutil -addstore -user Root root.crt`, then confirm the prompt.
   Linux and macOS: add it to the system trust store.
5. Open `https://veritra.home.arpa` in Edge or Chrome first (Firefox has its own
   trust store and would give a wrong answer). If the lock shows, the app
   should work too.
6. In the Veritra app, enter `https://veritra.home.arpa`.

Safety notes:

- Install the CA only on PCs you control. Anyone holding `root.key` can
  impersonate any site on a PC that trusts the CA; keep it on the server.
- Android phones do not trust user-installed CAs for apps; use Path A there.
- Open ports 80 and 443 on the server PC's firewall for the LAN only.
- Never use plain `http://` outside the loopback demo.

**What is verified:** the server-side profile and its checks exist
(`scripts/smoke-deploy.sh`). Using Path B from a real second Windows PC has
**not** been tested; whether the Windows desktop app trusts the Windows
certificate store is expected (about 80% confidence, based on how Dart's TLS
works on Windows) but unmeasured. First check on the second PC: the browser
test in step 5.
