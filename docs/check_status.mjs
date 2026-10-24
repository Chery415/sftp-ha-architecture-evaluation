async function run() {
  const loginRes = await fetch('http://localhost:8081/web/admin/login');
  const loginHtml = await loginRes.text();
  const formToken = loginHtml.match(/name="_form_token" value="([^"]+)"/)[1];
  const postRes = await fetch('http://localhost:8081/web/admin/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'username=admin&password=Password123!&_form_token=' + encodeURIComponent(formToken),
    redirect: 'manual'
  });
  const cookie = postRes.headers.get('set-cookie').split(';')[0];
  const statRes = await fetch('http://localhost:8081/web/admin/status', { headers: { 'Cookie': cookie } });
  const statHtml = await statRes.text();
  const tables = [...statHtml.matchAll(/<table[^>]*id="([^"]+)"[^>]*>/g)].map(m => m[1]);
  console.log('Status table IDs:', tables);
  const cardMatches = [...statHtml.matchAll(/<div[^>]+class="[^"]*card[^"]*"[^>]*>/g)];
  console.log('Cards count:', cardMatches.length);
}
run();
