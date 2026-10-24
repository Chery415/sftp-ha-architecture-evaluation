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
  
  const defRes = await fetch('http://localhost:8081/web/admin/defender', { headers: { 'Cookie': cookie } });
  const defHtml = await defRes.text();
  console.log('Defender table snippet:', defHtml.substring(defHtml.indexOf('<table'), defHtml.indexOf('<table') + 500));
  
  const statRes = await fetch('http://localhost:8081/web/admin/status', { headers: { 'Cookie': cookie } });
  const statHtml = await statRes.text();
  console.log('Status table snippet:', statHtml.substring(statHtml.indexOf('<table'), statHtml.indexOf('<table') + 500));
}
run();
