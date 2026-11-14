// Cloudflare Web Analytics: cookieless, no personal data, no consent banner needed.
// Paste the site token from Cloudflare → Analytics & Logs → Web Analytics → twofoldapp.org.
// While the token is empty, nothing loads.
const CLOUDFLARE_ANALYTICS_TOKEN = "";

if (CLOUDFLARE_ANALYTICS_TOKEN) {
  const s = document.createElement("script");
  s.defer = true;
  s.src = "https://static.cloudflareinsights.com/beacon.min.js";
  s.dataset.cfBeacon = JSON.stringify({ token: CLOUDFLARE_ANALYTICS_TOKEN });
  document.head.appendChild(s);
}
