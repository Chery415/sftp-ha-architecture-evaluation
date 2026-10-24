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
  console.log('Edit partner_vendor status:', userRes.status);
  const userHtml = await userRes.text();
  console.log('Edit user snippet:', userHtml.substring(userHtml.indexOf('<h1') !== -1 ? userHtml.indexOf('<h1') : 500, 1000));
}
run();
