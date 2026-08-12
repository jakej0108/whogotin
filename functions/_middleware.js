// Cloudflare Pages Function — does the same job as a "_redirects" SPA
// fallback rule, but through actual code instead of the "_redirects" file
// parser, since that parser has repeatedly failed on Direct Upload
// deploys (a known Cloudflare bug, not specific to this project).
//
// Any request for a real file (something with a file extension, like
// index.html, og-image.png, or this functions folder's own files) is
// left alone. Anything else — /ucla, /submission/4f8a2e91,
// /school/ucla/4f8a2e91, etc. — has no matching file on disk, so instead
// of letting Cloudflare 404 it, this serves index.html's contents while
// leaving the URL in the visitor's address bar untouched. The app's own
// JavaScript then reads that URL and shows the right page.
export async function onRequest(context) {
  const url = new URL(context.request.url);

  if (url.pathname.includes('.')) {
    return context.next();
  }

  const indexUrl = new URL('/index.html', url);
  return context.env.ASSETS.fetch(new Request(indexUrl, context.request));
}
