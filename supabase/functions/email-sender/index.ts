// email-sender: sends whatever is due in public.email_outbox.
//
// Called every minute by pg_cron (sql/email_cron.sql) with the
// x-cron-secret header. claim_email_batch() has already dropped rows the
// person shouldn't get (unverified, category off, ...), so everything it
// returns is sent. Each row is then marked with finish_email().
//
// Secrets (supabase secrets set ...):
//   CRON_SECRET      same value as the Vault secret email_cron_secret
//   RESEND_API_KEY   from resend.com -> API Keys
//   EMAIL_FROM       e.g. "Who Got In <hello@whogotin.com>" (domain verified in Resend)
//   MAILING_ADDRESS  physical/PO box address printed in the footer (CAN-SPAM)
//   SITE_URL         optional, defaults to https://whogotin.com
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? '';
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const EMAIL_FROM = Deno.env.get('EMAIL_FROM') ?? 'Who Got In <hello@whogotin.com>';
const MAILING_ADDRESS = Deno.env.get('MAILING_ADDRESS') ?? '';
const SITE_URL = (Deno.env.get('SITE_URL') ?? 'https://whogotin.com').replace(/\/+$/, '');
const UNSUB_ENDPOINT = `${SUPABASE_URL}/functions/v1/unsubscribe`;

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

type Row = {
  id: number;
  user_id: string;
  kind: 'verify' | 'reply' | 'waitlist' | 'digest' | 'update';
  payload: Record<string, any>;
  attempts: number;
  email: string;
  unsub_token: string;
};

type Email = { subject: string; heading: string; paragraphs: string[]; button?: { label: string; url: string } };

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

// Same as slugify() in index.html: school pages live at /<slug>.
function slugify(text: string): string {
  return String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
}

// "USC and UCLA" / "USC, UCLA, and 2 more"
function nameList(names: string[]): string {
  if (names.length <= 1) return names[0] ?? '';
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names[0]}, ${names[1]}, and ${names.length - 2} more`;
}

function build(row: Row): Email | null {
  const p = row.payload || {};
  switch (row.kind) {
    case 'verify':
      if (!p.token) return null;
      return {
        subject: 'Confirm your email for Who Got In',
        heading: 'Confirm your email',
        paragraphs: [
          'Tap the button to confirm this address. Until you do, we won\'t send you anything else.',
          'If you didn\'t ask for this, ignore this email and nothing will happen.',
        ],
        button: { label: 'Confirm email', url: `${SITE_URL}/email/verify?token=${encodeURIComponent(p.token)}` },
      };
    case 'reply': {
      const url = p.parent_type === 'post'
        ? `${SITE_URL}/discussions/${p.parent_id}`
        : `${SITE_URL}/submission/${p.short_id}`;
      const who = p.handle ? `${p.handle}` : 'Someone';
      const what = p.is_reply ? 'replied to your comment' : (p.parent_type === 'post' ? 'commented on your post' : 'commented on your result');
      return {
        subject: `${who} ${what}`,
        heading: `${who} ${what}`,
        paragraphs: [p.excerpt ? `“${p.excerpt}”` : ''].filter(Boolean),
        button: { label: 'See the conversation', url: `${url}#comments` },
      };
    }
    case 'waitlist':
      return {
        subject: `Someone just got off the waitlist at ${p.school}`,
        heading: `The waitlist moved at ${p.school}`,
        paragraphs: ['Someone on Who Got In just reported getting in off the waitlist.'],
        button: { label: `See ${p.school}`, url: `${SITE_URL}/${slugify(p.school)}` },
      };
    case 'digest': {
      const schools: { name: string; count: number }[] = Array.isArray(p.schools) ? p.schools : [];
      if (!schools.length) return null; // never send an empty digest
      const lines = schools.slice(0, 10).map((s) => `${s.name}: ${s.count} new result${s.count === 1 ? '' : 's'}`);
      return {
        subject: `${p.total} new results at ${nameList(schools.map((s) => s.name))}`,
        heading: 'New results at your schools',
        paragraphs: lines,
        button: { label: 'See the results', url: `${SITE_URL}/${slugify(schools[0].name)}` },
      };
    }
    case 'update':
      if (!p.subject || !p.body) return null;
      return {
        subject: String(p.subject),
        heading: String(p.subject),
        paragraphs: String(p.body).split(/\n{2,}/),
      };
  }
  return null;
}

function render(row: Row, e: Email) {
  const prefsUrl = `${SITE_URL}/email/preferences?t=${encodeURIComponent(row.unsub_token)}`;
  const footerWhy = row.kind === 'verify'
    ? 'You\'re getting this because this address was entered on whogotin.com.'
    : 'You\'re getting this because of your email settings on whogotin.com.';
  const html = `<!doctype html><html><body style="margin:0;background:#fff;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#291313;">
<div style="max-width:520px;margin:0 auto;padding:28px 20px;">
  <div style="font-weight:700;font-size:15px;margin-bottom:18px;">Who Got In</div>
  <h1 style="font-size:20px;margin:0 0 14px;">${esc(e.heading)}</h1>
  ${e.paragraphs.map((t) => `<p style="font-size:15px;line-height:1.5;margin:0 0 12px;">${esc(t)}</p>`).join('')}
  ${e.button ? `<p style="margin:22px 0;"><a href="${esc(e.button.url)}" style="background:#B3261E;color:#fff;text-decoration:none;padding:11px 18px;border-radius:6px;font-weight:600;display:inline-block;">${esc(e.button.label)}</a></p>` : ''}
  <hr style="border:none;border-top:1px solid #F0DADA;margin:26px 0 14px;">
  <p style="font-size:12px;color:#7A6363;line-height:1.5;margin:0;">${esc(footerWhy)}
  <a href="${esc(prefsUrl)}" style="color:#7A6363;">Email preferences / unsubscribe</a>${MAILING_ADDRESS ? `<br>${esc(MAILING_ADDRESS)}` : ''}</p>
</div></body></html>`;
  const text = [
    e.heading, '', ...e.paragraphs, '',
    e.button ? `${e.button.label}: ${e.button.url}` : '', '',
    '--', footerWhy, `Email preferences / unsubscribe: ${prefsUrl}`, MAILING_ADDRESS,
  ].filter((l, i, a) => l !== '' || a[i - 1] !== '').join('\n');
  const headers: Record<string, string> = {};
  if (row.kind !== 'verify') {
    headers['List-Unsubscribe'] = `<${UNSUB_ENDPOINT}?t=${encodeURIComponent(row.unsub_token)}>`;
    headers['List-Unsubscribe-Post'] = 'List-Unsubscribe=One-Click';
  }
  return { html, text, headers };
}

async function send(row: Row): Promise<void> {
  const e = build(row);
  if (!e) throw new Error(`nothing to send for kind ${row.kind}`);
  const { html, text, headers } = render(row, e);
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
      // Resend drops a repeat with the same key, so a crash between sending
      // and finish_email() can't produce a second copy.
      'Idempotency-Key': `outbox-${row.id}`,
    },
    body: JSON.stringify({ from: EMAIL_FROM, to: [row.email], subject: e.subject, html, text, headers }),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 500)}`);
}

Deno.serve(async (req) => {
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) {
    return new Response('forbidden', { status: 403 });
  }
  if (!RESEND_API_KEY) return new Response('RESEND_API_KEY is not set', { status: 500 });

  let sent = 0, failed = 0;
  const started = Date.now();
  // Keep going while there's work, but stay well inside the cron interval.
  while (Date.now() - started < 40_000) {
    const { data, error } = await db.rpc('claim_email_batch', { p_limit: 50 });
    if (error) return new Response(`claim failed: ${error.message}`, { status: 500 });
    const rows = (data ?? []) as Row[];
    if (!rows.length) break;
    for (const row of rows) {
      try {
        await send(row);
        await db.rpc('finish_email', { p_id: row.id, p_ok: true });
        sent++;
      } catch (err) {
        await db.rpc('finish_email', { p_id: row.id, p_ok: false, p_error: String(err) });
        failed++;
      }
      // Resend's default limit is 2 requests per second.
      await new Promise((r) => setTimeout(r, 550));
    }
  }
  return Response.json({ sent, failed });
});
