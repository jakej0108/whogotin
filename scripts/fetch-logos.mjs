#!/usr/bin/env node
/*
 * Fetch university logos once and store them in logos/<domain>.png.
 *
 * For each school in the `universities` table that has a `domain`, this
 * looks at the school's own homepage for its high-resolution site icon
 * (apple-touch-icon, or a large/SVG icon), resizes it to a 128x128 PNG and
 * saves it in logos/. Schools that already have a logo are skipped unless
 * --force is given. Icons smaller than 96px are skipped (they look blurry);
 * those schools keep showing their initials on the site.
 *
 * Also writes:
 *   logos/manifest.json   list of domains that have a logo (the site reads it)
 *   logos/_review.png     a contact sheet of every logo, newest marked, for review
 *   --report <file>       a Markdown summary (used as the PR description)
 *
 * Usage:
 *   npm install --prefix scripts
 *   node scripts/fetch-logos.mjs [--force] [--only ucla.edu,mit.edu] [--report out.md]
 *                                [--schools schools.json]
 *
 * Runs in GitHub Actions via .github/workflows/fetch-logos.yml.
 */
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LOGO_DIR = path.join(ROOT, 'logos');
const SIZE = 128;               // saved logo size (px)
const MIN_SOURCE = 64;          // smaller icons are skipped (stamps show at most 80 device px)
const TIMEOUT_MS = 15000;
const CONCURRENCY = 6;
// Many university sites block requests that don't look like a browser, so
// send the same headers a desktop Chrome would.
const BROWSER_HEADERS = {
  'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
};
const DOMAIN_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

// Public values; the same ones the website itself uses.
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://nczvyfkfppndhovlevxm.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_uNV8G11iBIAHZ6KTFXRe4w_zLEqmQ8Q';

function parseArgs(argv){
  const a = { force: false, only: null, report: null, schools: null };
  for(let i = 0; i < argv.length; i++){
    if(argv[i] === '--force') a.force = true;
    else if(argv[i] === '--only') a.only = new Set(String(argv[++i] || '').split(',').map(s => s.trim()).filter(Boolean));
    else if(argv[i] === '--report') a.report = argv[++i];
    else if(argv[i] === '--schools') a.schools = argv[++i];
  }
  return a;
}

async function fetchWithTimeout(url, opts = {}){
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    return await fetch(url, { redirect: 'follow', ...opts, signal: ctrl.signal, headers: { ...BROWSER_HEADERS, ...(opts.headers || {}) } });
  } finally { clearTimeout(t); }
}

async function loadSchools(file){
  if(file) return JSON.parse(await fs.readFile(file, 'utf8'));
  const url = `${SUPABASE_URL}/rest/v1/universities?select=name,domain&domain=not.is.null&order=name`;
  const res = await fetchWithTimeout(url, { headers: { apikey: SUPABASE_KEY, authorization: `Bearer ${SUPABASE_KEY}` } });
  if(!res.ok) throw new Error(`Could not load universities from Supabase: HTTP ${res.status} ${await res.text()}`);
  return res.json();
}

// Last resort: Google's favicon service, fetched once like everything else.
// Google crawls school sites itself, so this works for sites that block us.
// Returns 404 when it has nothing. LOGO_TEST_FALLBACK overrides it in tests.
export function fallbackIconUrl(domain){
  if(process.env.LOGO_TEST_FALLBACK) return process.env.LOGO_TEST_FALLBACK.replace('{domain}', domain);
  return `https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=${encodeURIComponent('https://www.' + domain + '/')}&size=256`;
}

// Homepages to try for a domain. LOGO_TEST_MAP ({"domain": "http://127.0.0.1:port/"})
// lets tests point domains at local servers.
export function siteUrls(domain){
  if(process.env.LOGO_TEST_MAP) return [JSON.parse(process.env.LOGO_TEST_MAP)[domain] || 'http://127.0.0.1:9/'];
  return [`https://www.${domain}/`, `https://${domain}/`];
}

const attr = (tag, name) => {
  const m = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'));
  return m ? (m[2] ?? m[3] ?? m[4] ?? '').trim() : '';
};

// Best icon candidates from a page's <link> tags, best first.
export function iconCandidates(html, pageUrl){
  const out = [];
  for(const tag of String(html).match(/<link\b[^>]*>/gi) || []){
    const rel = attr(tag, 'rel').toLowerCase().split(/\s+/);
    const href = attr(tag, 'href');
    if(!href || href.startsWith('data:')) continue;
    if(rel.includes('mask-icon')) continue;                 // one-colour Safari pin icon
    const isApple = rel.some(r => r.startsWith('apple-touch-icon'));
    const isIcon = rel.includes('icon');
    if(!isApple && !isIcon) continue;
    const type = attr(tag, 'type').toLowerCase();
    const sizes = attr(tag, 'sizes').toLowerCase();
    const isSvg = type === 'image/svg+xml' || /\.svg(\?|#|$)/i.test(href);
    const declared = sizes === 'any' ? 1024 : Math.max(0, ...sizes.split(/\s+/).map(s => parseInt(s, 10) || 0));
    let score = isApple ? 3000 + (declared || 180) : isSvg ? 2500 : declared >= MIN_SOURCE ? 2000 + declared : declared || 16;
    let url;
    try { url = new URL(href.replace(/&amp;/g, '&'), pageUrl).href; } catch { continue; }
    if(!/^https?:/i.test(url)) continue;
    out.push({ url, score, isSvg });
  }
  out.sort((a, b) => b.score - a.score);
  const seen = new Set();
  return out.filter(c => !seen.has(c.url) && seen.add(c.url));
}

// .ico files hold several sizes. Returns the largest one as something sharp
// can read: the embedded PNG, or raw RGBA decoded from a 24/32-bit bitmap.
export function largestFromIco(buf){
  if(buf.length < 6 || buf.readUInt16LE(0) !== 0 || buf.readUInt16LE(2) !== 1) return null;
  const count = buf.readUInt16LE(4);
  let best = null;
  for(let i = 0; i < count; i++){
    const o = 6 + i * 16;
    if(o + 16 > buf.length) break;
    const w = buf[o] || 256, size = buf.readUInt32LE(o + 8), off = buf.readUInt32LE(o + 12);
    if(off + size > buf.length || size < 8) continue;
    if(!best || w > best.w) best = { w, data: buf.subarray(off, off + size) };
  }
  if(!best) return null;
  const d = best.data;
  if(d.readUInt32BE(0) === 0x89504e47) return { input: d };                 // PNG inside
  const hdr = d.readUInt32LE(0), w = d.readInt32LE(4), h = Math.abs(d.readInt32LE(8)) / 2, bpp = d.readUInt16LE(14);
  if(hdr < 40 || w <= 0 || h <= 0 || w > 512 || h > 512 || (bpp !== 32 && bpp !== 24)) return null;
  const stride = Math.ceil((w * bpp / 8) / 4) * 4, maskStride = Math.ceil(w / 32) * 4;
  const px = d.subarray(hdr), mask = px.subarray(stride * h);
  const out = Buffer.alloc(w * h * 4);
  for(let y = 0; y < h; y++){
    const row = h - 1 - y;                                                  // bitmaps are stored bottom-up
    for(let x = 0; x < w; x++){
      const s = row * stride + x * (bpp / 8), t = (y * w + x) * 4;
      if(s + 2 >= px.length) return null;
      out[t] = px[s + 2]; out[t + 1] = px[s + 1]; out[t + 2] = px[s];
      if(bpp === 32) out[t + 3] = px[s + 3];
      else {
        const m = mask[row * maskStride + (x >> 3)];
        out[t + 3] = (m === undefined || !((m >> (7 - (x & 7))) & 1)) ? 255 : 0;
      }
    }
  }
  if(bpp === 32 && !out.some((v, i) => i % 4 === 3 && v)) for(let i = 3; i < out.length; i += 4) out[i] = 255;  // no alpha used
  return { input: out, raw: { width: w, height: h, channels: 4 } };
}

// Downloads an image and returns a 128x128 PNG buffer, or throws.
export async function toLogoPng(buf, isSvg){
  const ico = (!isSvg && buf.length > 6 && buf.readUInt16LE(0) === 0 && buf.readUInt16LE(2) === 1) ? largestFromIco(buf) : null;
  if(ico){
    const png = await sharp(ico.input, ico.raw ? { raw: ico.raw } : {}).png().toBuffer();
    return toLogoPng(png, false);
  }
  const img = sharp(buf, isSvg ? { density: 300 } : {});
  const meta = await img.metadata();
  const w = meta.width || 0, h = meta.height || 0;
  if(!isSvg && meta.format !== 'svg' && Math.min(w, h) < MIN_SOURCE) throw new Error(`too small (${w}x${h})`);
  const out = await sharp(buf, isSvg || meta.format === 'svg' ? { density: 300 } : {})
    .resize(SIZE, SIZE, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png({ compressionLevel: 9 })
    .toBuffer();
  // The site shows logos on white: reject ones that would be (nearly) invisible there.
  const onWhite = await sharp(out).flatten({ background: '#ffffff' }).png().toBuffer();   // stats() reads its input, so render first
  const st = await sharp(onWhite).stats();
  const spread = Math.max(...st.channels.slice(0, 3).map(c => c.stdev));
  const minLum = Math.min(...st.channels.slice(0, 3).map(c => c.min));
  if(spread < 6 || minLum > 225) throw new Error('blank on a white background');
  return out;
}

async function download(url){
  const res = await fetchWithTimeout(url);
  if(!res.ok) throw new Error(`HTTP ${res.status}`);
  const len = Number(res.headers.get('content-length') || 0);
  if(len > 5e6) throw new Error('file too large');
  const buf = Buffer.from(await res.arrayBuffer());
  if(buf.length > 5e6) throw new Error('file too large');
  return { buf, type: (res.headers.get('content-type') || '').toLowerCase() };
}

const errText = e => e.name === 'AbortError' ? 'timeout' : (e.cause && e.cause.code) || e.message;

// Returns { ok: true, png, source } or { ok: false, reason, tried }.
export async function fetchLogo(domain){
  const tried = [];
  let homepage = null;            // how the homepage request went (for the report)
  for(const page of siteUrls(domain)){
    let html = '', finalUrl = page;
    try {
      const res = await fetchWithTimeout(page);
      finalUrl = res.url || page;
      if(res.ok){ html = (await res.text()).slice(0, 2e6); homepage = 'ok'; }
      else { tried.push(`${page} → HTTP ${res.status}`); homepage = homepage || `homepage blocked (HTTP ${res.status})`; }
    } catch(e){ tried.push(`${page} → ${errText(e)}`); homepage = homepage || `homepage unreachable (${errText(e)})`; continue; }
    const cands = iconCandidates(html, finalUrl);
    for(const p of ['/apple-touch-icon.png', '/apple-touch-icon-precomposed.png', '/favicon.ico']){
      cands.push({ url: new URL(p, finalUrl).href, score: 0, isSvg: false });
    }
    for(const c of cands){
      try {
        const { buf, type } = await download(c.url);
        const png = await toLogoPng(buf, c.isSvg || type.includes('svg'));
        return { ok: true, png, source: c.url };
      } catch(e){ tried.push(`${c.url} → ${errText(e)}`); }
    }
    if(html) break;   // the page loaded; another homepage URL won't have different icons
  }
  // Last resort: Google's copy of the site icon.
  const fb = fallbackIconUrl(domain);
  try {
    const { buf, type } = await download(fb);
    const png = await toLogoPng(buf, type.includes('svg'));
    return { ok: true, png, source: 'Google favicon service' };
  } catch(e){ tried.push(`Google favicon service → ${errText(e)}`); }

  const reason = tried.some(t => t.includes('blank on a white'))
    ? 'logo is white or blank (invisible on white)'
    : tried.some(t => t.includes('too small'))
      ? 'only small icons found'
      : homepage && homepage !== 'ok' ? homepage : 'no usable icon on the homepage';
  return { ok: false, reason, tried };
}

async function existingLogos(){
  await fs.mkdir(LOGO_DIR, { recursive: true });
  return new Set((await fs.readdir(LOGO_DIR)).filter(f => f.endsWith('.png')).map(f => f.slice(0, -4)).filter(d => DOMAIN_RE.test(d)));
}

const xmlEsc = s => String(s).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));

async function reviewSheet(entries, newSet){
  const cols = 8, cw = 170, ch = 190, pad = 21;
  const rows = Math.max(1, Math.ceil(entries.length / cols));
  const W = cols * cw, H = rows * ch + 40;
  const layers = [];
  let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="100%" height="100%" fill="#fff"/>`
    + `<text x="12" y="26" font-family="sans-serif" font-size="16" fill="#291313">${entries.length} logos. Red border = new this run. Delete any that look wrong.</text>`;
  for(const [i, e] of entries.entries()){
    const x = (i % cols) * cw, y = 40 + Math.floor(i / cols) * ch;
    svg += `<rect x="${x + 4}" y="${y + 4}" width="${cw - 8}" height="${ch - 8}" rx="8" fill="#fafafa" stroke="${newSet.has(e.domain) ? '#B3261E' : '#eee'}" stroke-width="${newSet.has(e.domain) ? 3 : 1}"/>`
      + `<text x="${x + cw / 2}" y="${y + ch - 30}" font-family="sans-serif" font-size="11" text-anchor="middle" fill="#291313">${xmlEsc(e.label.slice(0, 26))}</text>`
      + `<text x="${x + cw / 2}" y="${y + ch - 15}" font-family="sans-serif" font-size="10" text-anchor="middle" fill="#7A6363">${xmlEsc(e.domain)}</text>`;
    layers.push({ input: path.join(LOGO_DIR, e.domain + '.png'), left: x + pad, top: y + 12 });
  }
  svg += '</svg>';
  await sharp(Buffer.from(svg)).composite(layers).png({ compressionLevel: 9 }).toFile(path.join(LOGO_DIR, '_review.png'));
}

async function pool(items, n, fn){
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while(i < items.length){ const k = i++; out[k] = await fn(items[k], k); }
  }));
  return out;
}

async function main(){
  const args = parseArgs(process.argv.slice(2));
  const schools = (await loadSchools(args.schools)).filter(s => s.domain && DOMAIN_RE.test(s.domain));
  const namesByDomain = new Map();
  for(const s of schools){ (namesByDomain.get(s.domain) || namesByDomain.set(s.domain, []).get(s.domain)).push(s.name); }
  const have = await existingLogos();
  const todo = [...namesByDomain.keys()].filter(d => (!args.only || args.only.has(d)) && (args.force || !have.has(d)));
  console.log(`${namesByDomain.size} domains, ${have.size} logos already saved, fetching ${todo.length}…`);

  const added = [], failed = [];
  await pool(todo, CONCURRENCY, async (domain) => {
    const r = await fetchLogo(domain);
    if(r.ok){
      await fs.writeFile(path.join(LOGO_DIR, domain + '.png'), r.png);
      added.push({ domain, source: r.source });
      console.log(`✓ ${domain}  (${r.source})`);
    } else {
      failed.push({ domain, reason: r.reason, tried: r.tried });
      console.log(`✗ ${domain}  ${r.reason}`);
    }
  });

  const now = await existingLogos();
  const manifest = [...now].filter(d => namesByDomain.has(d)).sort();
  await fs.writeFile(path.join(LOGO_DIR, 'manifest.json'), JSON.stringify(manifest, null, 0) + '\n');
  const label = d => (namesByDomain.get(d) || [d]).join(' / ');
  const newSet = new Set(added.map(a => a.domain));
  const entries = manifest.map(d => ({ domain: d, label: label(d) }))
    .sort((a, b) => (newSet.has(b.domain) - newSet.has(a.domain)) || a.label.localeCompare(b.label));
  if(entries.length) await reviewSheet(entries, newSet);

  const missing = [...namesByDomain.keys()].filter(d => !now.has(d)).sort();
  const repo = process.env.GITHUB_REPOSITORY;
  const sheetUrl = repo ? `https://github.com/${repo}/blob/${process.env.LOGO_BRANCH || 'logos/update'}/logos/_review.png?raw=true` : 'logos/_review.png';
  const md = [
    `## University logos`,
    ``,
    `- **${added.length}** new logo${added.length === 1 ? '' : 's'} fetched this run`,
    `- **${manifest.length}** of ${namesByDomain.size} schools now have a logo`,
    `- **${missing.length}** without one (they keep showing their initials)`,
    ``,
    `### Review`,
    `Look over the sheet below (new ones have a red border). If a logo looks wrong, delete \`logos/<domain>.png\` in this PR and that school falls back to its initials.`,
    ``,
    `![Logo review sheet](${sheetUrl})`,
    ``,
    missing.length ? `### No logo (${missing.length})\n` + missing.map(d => `- ${label(d)} — \`${d}\`${(failed.find(f => f.domain === d) || {}).reason ? ': ' + failed.find(f => f.domain === d).reason : ''}`).join('\n') : '',
    failed.length ? `\n<details><summary>What was tried for each school without a logo</summary>\n\n` + failed.sort((a, b) => a.domain.localeCompare(b.domain)).map(f => `**${f.domain}**\n` + f.tried.slice(0, 8).map(t => `- ${t.replace(/[<>]/g, '')}`).join('\n')).join('\n\n') + `\n\n</details>` : '',
    ``,
    `Logos come from each school's own website (its high-resolution site icon), or Google's copy of it when the site can't be reached, and are trademarks of their respective owners.`,
    ``,
    `_Generated by \`scripts/fetch-logos.mjs\`._`,
  ].join('\n');
  if(args.report) await fs.writeFile(args.report, md);
  console.log(`\nDone: ${added.length} added, ${failed.length} failed, ${manifest.length}/${namesByDomain.size} schools have logos.`);
}

if(process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)){
  main().catch(e => { console.error(e); process.exit(1); });
}
