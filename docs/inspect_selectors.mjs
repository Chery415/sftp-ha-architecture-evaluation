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
  console.log('Got cookie:', cookie);
  
  const userPageRes = await fetch('http://localhost:8081/web/admin/user?action=edit&username=partner_vendor', {
    headers: { 'Cookie': cookie }
  });
  const userHtml = await userPageRes.text();
  
  const inputs = [...userHtml.matchAll(/<(?:input|select|textarea)[^>]+name="([^"]+)"/g)].map(m => m[1]);
  console.log('User form names:', [...new Set(inputs)]);
}
run().catch(console.error);
