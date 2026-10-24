import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';

const outDir = 'd:/Antigravity/Zabbix Lab/docs/screenshots';
if (!fs.existsSync(outDir)) {
  fs.mkdirSync(outDir, { recursive: true });
}

// 1. Launch Chrome
const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const chrome = spawn(chromePath, [
  '--headless=new',
  '--remote-debugging-port=9222',
  `--user-data-dir=${process.env.TEMP}\\chrome-cdp-sftpgo`,
  '--window-size=1440,960',
  '--lang=zh-TW',
  '--disable-gpu',
  '--no-first-run',
  '--no-default-browser-check'
]);

await new Promise(r => setTimeout(r, 2000));

try {
  // 2. Create a new target
  const newTargetRes = await fetch('http://127.0.0.1:9222/json/new?http://localhost:8081/web/admin/login', { method: 'PUT' });
  const target = await newTargetRes.json();
  const wsUrl = target.webSocketDebuggerUrl;

  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });

  let idCounter = 1;
  const pending = new Map();

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  };

  function send(method, params = {}) {
    return new Promise((resolve) => {
      const id = idCounter++;
      pending.set(id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });
  }

  await send('Page.enable');
  await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1440,
    height: 960,
    deviceScaleFactor: 1,
    mobile: false
  });

  async function snap(name, waitMs = 1500) {
    await new Promise(r => setTimeout(r, waitMs));
    const res = await send('Page.captureScreenshot', { format: 'png' });
    if (res.result && res.result.data) {
      const filePath = path.join(outDir, `${name}.png`);
      fs.writeFileSync(filePath, Buffer.from(res.result.data, 'base64'));
      console.log(`Saved screenshot: ${name}.png`);
    } else {
      console.error(`Failed to capture: ${name}`, res);
    }
  }

  async function nav(url) {
    await send('Page.navigate', { url });
    await new Promise(r => setTimeout(r, 1200));
  }

  async function evalCode(expression) {
    return await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  }

  // 1. Capture Login Screen
  await nav('http://localhost:8081/web/admin/login');
  await snap('01_admin_login');

  // 2. Perform Login
  await evalCode(`
    document.querySelector('input[name="username"]').value = 'admin';
    document.querySelector('input[name="password"]').value = 'Password123!';
    document.querySelector('#sign_in_form').submit();
  `);
  await new Promise(r => setTimeout(r, 2000));

  // 3. Users Management List
  await nav('http://localhost:8081/web/admin/users');
  await snap('02_users_list');

  // 4. User Edit / Details (Click into sftpuser or navigate to user creation/edit)
  await nav('http://localhost:8081/web/admin/user?action=edit&username=sftpuser');
  await snap('03_user_edit_general');

  // Scroll down to permissions
  await evalCode(`window.scrollTo(0, 700);`);
  await snap('04_user_permissions_acl');

  // Scroll to Storage S3 section
  await evalCode(`window.scrollTo(0, 1500);`);
  await snap('05_user_storage_s3');

  // Scroll to Quotas & Bandwidth section
  await evalCode(`window.scrollTo(0, 2400);`);
  await snap('06_user_quota_limits');

  // 5. Active Defender Security
  await nav('http://localhost:8081/web/admin/defender');
  await snap('07_defender_security');

  // 6. Real-time Status / Connections
  await nav('http://localhost:8081/web/admin/status');
  await snap('08_status_connections');

  // 7. Folders / Virtual Directories
  await nav('http://localhost:8081/web/admin/folders');
  await snap('09_virtual_folders');

  // 8. Web Client (End-user Explorer)
  await nav('http://localhost:8081/web/client/login');
  await snap('10_web_client_login');

  ws.close();
} catch (e) {
  console.error('Error during capture:', e);
} finally {
  chrome.kill();
  console.log('Capture script finished.');
}
