/*
 * Paste this into the DevTools Console while you are logged in and have an
 * open session at https://app.devin.ai. It collects every document.cookie
 * pair and prints a single string you can paste into DEVIN_COOKIE in your
 * gateway .env file.
 *
 * Notes:
 * - storage_auth1_session is set as a regular (non-HttpOnly) cookie, so it is
 *   available to document.cookie.
 * - Truly HttpOnly cookies cannot be read here. If the gateway later complains
 *   that the bearer is missing, also copy the "Cookie" header from any XHR
 *   in the Network tab (right-click a request -> Copy -> Copy as cURL, then
 *   pull out the -H 'Cookie: ...' value).
 */
(() => {
  const text = document.cookie;
  console.log('--- DEVIN_COOKIE ---');
  console.log(text);
  navigator.clipboard?.writeText(text).then(
    () => console.log('Copied to clipboard.'),
    () => console.log('Could not copy automatically. Copy the line above.'),
  );
  return text;
})();
