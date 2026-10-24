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
  const usersRes = await fetch('http://localhost:8081/web/admin/users', { headers: { 'Cookie': cookie } });
  const usersHtml = await usersRes.text();
  const tables = [...usersHtml.matchAll(/<table[^>]*id="([^"]+)"[^>]*>/g)].map(m => m[1]);
  console.log('Users tables:', tables);
  const links = [...usersHtml.matchAll(/<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g)].map(m => ({ href: m[1], text: m[2].trim() }));
  console.log('Add user button link:', links.find(l => l.href.includes('user?action=add')));
}
run();
