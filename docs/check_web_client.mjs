async function run() {
  const loginRes = await fetch('http://localhost:8081/web/client/login');
  const loginHtml = await loginRes.text();
  const formToken = loginHtml.match(/name="_form_token" value="([^"]+)"/)[1];
  
  const postRes = await fetch('http://localhost:8081/web/client/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'username=sftpuser&password=sftp123456&_form_token=' + encodeURIComponent(formToken),
    redirect: 'manual'
  });
  console.log('Web client login status:', postRes.status);
  const cookie = postRes.headers.get('set-cookie');
  console.log('Web client cookie:', cookie ? cookie.split(';')[0] : 'none');
  
  const filesRes = await fetch('http://localhost:8081/web/client/files', {
    headers: { 'Cookie': cookie }
  });
  console.log('Files page status:', filesRes.status);
  const filesHtml = await filesRes.text();
  console.log('Files html snippet:', filesHtml.substring(filesHtml.indexOf('<table'), filesHtml.indexOf('<table') + 500));
}
run();
