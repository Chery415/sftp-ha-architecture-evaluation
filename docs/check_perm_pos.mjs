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
  const userRes = await fetch('http://localhost:8081/web/admin/user/partner_vendor', { headers: { 'Cookie': cookie } });
  const userHtml = await userRes.text();
  const permIdx = userHtml.indexOf('name="permissions"');
  console.log('Perm index in html:', permIdx);
  const headings = [...userHtml.matchAll(/<(?:h[1-6]|label|legend)[^>]*>([\s\S]*?)<\/(?:h[1-6]|label|legend)>/g)].map(m => m[1].trim());
  console.log('Form section labels around perm:', headings.filter(h => h.includes('Perm') || h.includes('ACL') || h.includes('Directory') || h.includes('Quota')));
}
run();
