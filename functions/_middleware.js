const DEFAULT_SUPABASE_URL = 'https://nczvyfkfppndhovlevxm.supabase.co';
const DEFAULT_SUPABASE_KEY = 'sb_publishable_uNV8G11iBIAHZ6KTFXRe4w_zLEqmQ8Q';

export async function onRequest(context) {
  const requestUrl = new URL(context.request.url);
  const submission = requestUrl.pathname.match(/^\/submission\/([a-z0-9]+)\/?$/i);

  // Static files use the normal asset pipeline. Extensionless URLs retain
  // the existing single-page-app fallback to index.html.
  if (!submission && /\.[a-z0-9]+$/i.test(requestUrl.pathname)) {
    return context.next();
  }

  const indexUrl = new URL('/index.html', requestUrl.origin);
  const indexResponse = await context.env.ASSETS.fetch(new Request(indexUrl, context.request));
  if (!submission) return indexResponse;

  const supabaseUrl = context.env.SUPABASE_URL || DEFAULT_SUPABASE_URL;
  const supabaseKey = context.env.SUPABASE_ANON_KEY || DEFAULT_SUPABASE_KEY;
  const shortId = submission[1].toLowerCase();
  let rows = [];

  try {
    const apiUrl = new URL('/rest/v1/profiles', supabaseUrl);
    apiUrl.searchParams.set('select', 'university,status,major,gpa,weighted_gpa,sat,act,transfer,class_year');
    apiUrl.searchParams.set('share_short_id', `eq.${shortId}`);
    apiUrl.searchParams.set('order', 'created_at.asc');
    const result = await fetch(apiUrl, {
      headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` }
    });
    if (result.ok) rows = await result.json();
  } catch (error) {
    console.error('Submission metadata lookup failed', error);
  }

  if (!rows.length) return indexResponse;

  const rep = rows[0];
  const accepted = rows.filter(row => row.status === 'accepted').map(row => row.university);
  const resultSummary = accepted.length
    ? `Accepted to ${accepted.slice(0, 3).join(', ')}${accepted.length > 3 ? ` +${accepted.length - 3} more` : ''}`
    : `${rows.length} college admission result${rows.length === 1 ? '' : 's'}`;
  const title = `${resultSummary} | Who Got In`;
  const stats = [rep.gpa != null ? `GPA ${rep.gpa}` : '', rep.major || '', rep.sat ? `SAT ${rep.sat}` : '', rep.act ? `ACT ${rep.act}` : ''].filter(Boolean);
  const description = `${stats.join(' · ')}${stats.length ? '. ' : ''}See this applicant's self-reported college admission results.`;
  const canonicalUrl = `${requestUrl.origin}/submission/${shortId}`;

  return new HTMLRewriter()
    .on('title', new TextElement(title))
    .on('meta[name="description"]', new MetaElement(description))
    .on('meta[property="og:title"]', new MetaElement(title))
    .on('meta[property="og:description"]', new MetaElement(description))
    .on('meta[property="og:url"]', new MetaElement(canonicalUrl))
    .on('meta[name="twitter:title"]', new MetaElement(title))
    .on('meta[name="twitter:description"]', new MetaElement(description))
    .transform(indexResponse);
}

class TextElement {
  constructor(value) { this.value = value; }
  element(element) { element.setInnerContent(this.value); }
}

class MetaElement {
  constructor(value) { this.value = value; }
  element(element) { element.setAttribute('content', this.value); }
}
