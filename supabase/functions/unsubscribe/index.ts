// unsubscribe: the URL in every email's List-Unsubscribe header.
//
//   POST ?t=<unsub_token>  one-click unsubscribe from Gmail/Apple Mail/etc.
//                          (RFC 8058). Turns off every category that can be
//                          turned off. Account emails still go out.
//   GET  ?t=<unsub_token>  someone opened the link in a browser: send them to
//                          the preferences page on the site.
//
// No login: the token is the key. Deploy with --no-verify-jwt.

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SITE_URL = (Deno.env.get('SITE_URL') ?? 'https://whogotin.com').replace(/\/+$/, '');
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get('t') ?? '';
  if (req.method === 'GET') {
    return Response.redirect(`${SITE_URL}/email/preferences?t=${encodeURIComponent(token)}`, 302);
  }
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  if (!/^[0-9a-f]{32,}$/.test(token)) return new Response('invalid link', { status: 400 });

  const { error } = await db.rpc('unsubscribe_all_by_token', { p_token: token });
  if (error) return new Response('error', { status: 500 });
  return new Response('unsubscribed', { status: 200 });
});
