# Edge Functions

| Function | Called by | What it does |
|---|---|---|
| `email-sender` | pg_cron, every minute (`sql/email_cron.sql`) | Sends everything due in `email_outbox` through Resend |
| `unsubscribe` | Mail apps (List-Unsubscribe one-click POST) and email links | One-click unsubscribe; a GET goes to `/email/preferences` |

Neither function takes a user JWT. `email-sender` checks the `x-cron-secret`
header and `unsubscribe` uses the token in the link, so both are deployed
with JWT verification off (also set in `supabase/config.toml`).

## One-time setup

1. **Resend.** Add and verify the `whogotin.com` domain. Resend shows the DNS
   records to add in Cloudflare DNS: SPF (TXT), DKIM (CNAME/TXT) and a return
   path. Also add DMARC yourself: a TXT record on `_dmarc.whogotin.com` with
   `v=DMARC1; p=none; rua=mailto:whogotincontact@gmail.com`. After a few
   clean weeks, change `p=none` to `p=quarantine`.
2. **Secrets.** Put a long random string in `CRON_SECRET`, for example from
   `openssl rand -hex 32`:

   ```bash
   supabase secrets set CRON_SECRET=... RESEND_API_KEY=re_... \
     EMAIL_FROM="Who Got In <hello@whogotin.com>" \
     MAILING_ADDRESS="Who Got In, PO Box ..., City, ST 00000"
   ```

3. **Deploy.**

   ```bash
   supabase functions deploy email-sender --no-verify-jwt
   ```

   ```bash
   supabase functions deploy unsubscribe --no-verify-jwt
   ```

4. **Schedule.** Save the same `CRON_SECRET` in Vault, then run `sql/email_cron.sql`.
   The steps are at the top of that file.

## Supabase Auth settings (for magic-link sign-in)

- Authentication → Providers → Email: enabled. "Confirm email" can stay on.
- Authentication → URL Configuration → Redirect URLs: add
  `https://whogotin.com/**`. Add `http://localhost:*/**` too if you test locally.
- Authentication → Emails → Magic Link: optionally edit the template. Supabase
  sends sign-in emails itself; they don't go through `email_outbox`.
- For real volume, set Authentication → SMTP Settings to Resend's SMTP
  (`smtp.resend.com`) so sign-in links come from your domain too.
