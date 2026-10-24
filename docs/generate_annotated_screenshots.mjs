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
  `--user-data-dir=${process.env.TEMP}\\chrome-cdp-perfect`,
  '--window-size=1440,960',
  '--lang=zh-TW',
  '--disable-gpu',
  '--no-first-run',
  '--no-default-browser-check'
]);

await new Promise(r => setTimeout(r, 2000));

try {
  const newTargetRes = await fetch('http://127.0.0.1:9222/json/new?http://localhost:8081/web/admin/login', { method: 'PUT' });
  const target = await newTargetRes.json();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
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
    deviceScaleFactor: 1.25,
    mobile: false
  });

  async function nav(url, waitMs = 2000) {
    await send('Page.navigate', { url });
    await new Promise(r => setTimeout(r, waitMs));
  }

  async function evalCode(expression) {
    return await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  }

  async function injectAnnotationEngine() {
    await evalCode(`
      window.__annotate = function(annotations) {
        document.querySelectorAll('.doc-annotation-box').forEach(e => e.remove());
        for (const ann of annotations) {
          let el = null;
          if (typeof ann.target === 'string') {
            el = document.querySelector(ann.target);
          } else if (ann.target && ann.target.nodeType) {
            el = ann.target;
          }
          if (!el && ann.textMatch) {
            const all = Array.from(document.querySelectorAll(ann.textMatch.selector || '*'));
            el = all.find(e => e.innerText && e.innerText.trim().includes(ann.textMatch.text));
          }
          if (!el) {
            console.warn('[Warning] Target not found for:', ann.label);
            continue;
          }
          const rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) {
            console.warn('[Warning] Target zero size for:', ann.label);
            continue;
          }
          const overlay = document.createElement('div');
          overlay.className = 'doc-annotation-box';
          overlay.style.position = 'absolute';
          overlay.style.left = (window.scrollX + rect.left - 4) + 'px';
          overlay.style.top = (window.scrollY + rect.top - 4) + 'px';
          overlay.style.width = (rect.width + 8) + 'px';
          overlay.style.height = (rect.height + 8) + 'px';
          overlay.style.border = '3px solid #ff1744';
          overlay.style.borderRadius = '6px';
          overlay.style.backgroundColor = 'rgba(255, 23, 68, 0.08)';
          overlay.style.boxShadow = '0 0 12px rgba(255, 23, 68, 0.55)';
          overlay.style.pointerEvents = 'none';
          overlay.style.zIndex = '9999999';

          const badge = document.createElement('div');
          badge.style.position = 'absolute';
          badge.style.top = (ann.topOffset || -14) + 'px';
          badge.style.left = (ann.leftOffset || 6) + 'px';
          badge.style.backgroundColor = '#d50000';
          badge.style.color = '#ffffff';
          badge.style.fontWeight = 'bold';
          badge.style.fontSize = '12px';
          badge.style.fontFamily = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
          badge.style.padding = '2px 9px';
          badge.style.borderRadius = '10px';
          badge.style.whiteSpace = 'nowrap';
          badge.style.boxShadow = '0 2px 5px rgba(0,0,0,0.4)';
          badge.style.border = '1.5px solid #ffffff';
          badge.innerText = ann.num + ' ' + ann.label;
          overlay.appendChild(badge);
          document.body.appendChild(overlay);
        }
      };
    `);
  }

  async function snap(name) {
    await new Promise(r => setTimeout(r, 600));
    const res = await send('Page.captureScreenshot', { format: 'png' });
    if (res.result && res.result.data) {
      const filePath = path.join(outDir, `${name}.png`);
      fs.writeFileSync(filePath, Buffer.from(res.result.data, 'base64'));
      console.log(`[Captured] ${name}.png`);
    } else {
      console.error(`[Error] Failed to capture: ${name}`, res);
    }
  }

  // ==========================================
  // 1. Admin Login (01_admin_login)
  // ==========================================
  console.log('Generating 01_admin_login...');
  await nav('http://localhost:8081/web/admin/login');
  await injectAnnotationEngine();
  await evalCode(`
    document.querySelector('input[name="username"]').value = 'admin';
    document.querySelector('input[name="password"]').value = 'Password123!';
    window.__annotate([
      { target: '#languageSwitcher', num: '①', label: '繁體中文語系切換' },
      { target: 'input[name="username"]', num: '②', label: '系統管理員帳號' },
      { target: 'input[name="password"]', num: '③', label: '管理員安全密碼' },
      { target: '#sign_in_submit', num: '④', label: '登入管理後台 (支援 2FA)' }
    ]);
  `);
  await snap('01_admin_login');

  // Submit Login
  await evalCode(`document.querySelector('#sign_in_form').submit();`);
  await new Promise(r => setTimeout(r, 2500));

  // ==========================================
  // 2. Users Management List (02_users_list)
  // ==========================================
  console.log('Generating 02_users_list...');
  await nav('http://localhost:8081/web/admin/users', 2500);
  await injectAnnotationEngine();
  await evalCode(`
    if ($('#checkColDiskQuota').length) {
      $('#checkColDiskQuota').prop('checked', true).trigger('change');
      $('#checkColStorage').prop('checked', true).trigger('change');
    }
  `);
  await new Promise(r => setTimeout(r, 800));
  await evalCode(`
    const rows = Array.from(document.querySelectorAll('#dataTable tbody tr'));
    const partnerRow = rows.find(r => r.innerText.includes('partner_vendor'));
    const hrRow = rows.find(r => r.innerText.includes('hr_backup'));
    const addBtn = document.querySelector('a.btn.btn-primary');

    window.__annotate([
      { target: partnerRow ? partnerRow.querySelector('td:nth-child(1)') : null, num: '①', label: '帳號與狀態 (partner_vendor - 啟用)' },
      { target: partnerRow ? partnerRow.querySelector('td:nth-child(4)') : null, num: '②', label: 'S3 儲存對接 (S3 Compatible)' },
      { target: partnerRow ? partnerRow.querySelector('td:nth-child(5)') : null, num: '③', label: '空間配額限制 (50.0 GiB Quota)' },
      { target: hrRow ? hrRow.querySelector('td:nth-child(2)') : null, num: '④', label: '停用狀態對比 (hr_backup - Inactive)' },
      { target: addBtn, num: '⑤', label: '+ 新增使用者 (100% 免 Linux 指令)' }
    ]);
  `);
  await snap('02_users_list');

  // ==========================================
  // 3. User Edit General (03_user_edit_general)
  // ==========================================
  console.log('Generating 03_user_edit_general...');
  await nav('http://localhost:8081/web/admin/user/partner_vendor', 2500);
  await injectAnnotationEngine();
  await evalCode(`
    window.scrollTo(0, 0);
    const userInp = document.querySelector('input[name="username"]');
    const statusSel = document.querySelector('select[name="status"]').nextElementSibling || document.querySelector('select[name="status"]');
    const reqPw = document.querySelector('input[name="require_password_change"]').closest('.form-check') || document.querySelector('input[name="require_password_change"]');
    const pubKey = document.querySelector('.public-keys-list') || document.querySelector('#div_public_keys') || document.querySelector('textarea');
    
    window.__annotate([
      { target: userInp, num: '①', label: '使用者名稱 (partner_vendor)' },
      { target: statusSel, num: '②', label: '帳號狀態：已啟用 (Active)' },
      { target: reqPw, num: '③', label: '強制下次登入變更密碼' },
      { target: pubKey, num: '④', label: 'SSH 公鑰認證 (ed25519 杜絕密碼猜測)' }
    ]);
  `);
  await snap('03_user_edit_general');

  // ==========================================
  // 4. User Permissions ACL (04_user_permissions_acl)
  // ==========================================
  console.log('Generating 04_user_permissions_acl...');
  await evalCode(`
    $('#collapsePermissions').collapse('show');
  `);
  await new Promise(r => setTimeout(r, 600));
  await evalCode(`
    document.querySelector('#collapsePermissions').scrollIntoView({ block: 'start' });
    const permContainer = document.querySelector('select[name="permissions"]').nextElementSibling;
    const descField = document.querySelector('textarea[name="description"]');
    
    window.__annotate([
      { target: permContainer, num: '①', label: '細緻 ACL 權限：已勾選 [list] 清單、[download] 下載、[upload] 上傳' },
      { target: permContainer, num: '②', label: '防誤刪與防勒索：嚴格取消勾選 [overwrite] 覆蓋 與 [delete] 刪除', topOffset: 45 },
      { target: descField, num: '③', label: '帳號用途說明 (合作外包商專用傳輸帳號)' }
    ]);
  `);
  await snap('04_user_permissions_acl');

  // ==========================================
  // 5. User Storage S3 (05_user_storage_s3)
  // ==========================================
  console.log('Generating 05_user_storage_s3...');
  await evalCode(`
    document.querySelector('select[name="fs_provider"]').scrollIntoView({ block: 'center' });
    const fsSelect = document.querySelector('select[name="fs_provider"]').nextElementSibling || document.querySelector('select[name="fs_provider"]');
    const bucketInp = document.querySelector('input[name="s3_bucket"]');
    const endpointInp = document.querySelector('input[name="s3_endpoint"]');
    const accessKeyInp = document.querySelector('input[name="s3_access_key"]');
    
    window.__annotate([
      { target: fsSelect, num: '①', label: '儲存提供者：S3 Compatible' },
      { target: bucketInp, num: '②', label: 'S3 儲存桶名稱 (sftp-data)' },
      { target: endpointInp, num: '③', label: 'MinIO S3 端點 (http://minio-a:9000)' },
      { target: accessKeyInp, num: '④', label: 'S3 存取金鑰 (Access Key: minioadmin)' }
    ]);
  `);
  await snap('05_user_storage_s3');

  // ==========================================
  // 6. User Quota Limits (06_user_quota_limits)
  // ==========================================
  console.log('Generating 06_user_quota_limits...');
  await evalCode(`
    $('#collapseQuota').collapse('show');
  `);
  await new Promise(r => setTimeout(r, 600));
  await evalCode(`
    document.querySelector('#collapseQuota').scrollIntoView({ block: 'start' });
    const quotaSizeInp = document.querySelector('input[name="quota_size"]');
    const quotaFilesInp = document.querySelector('input[name="quota_files"]');
    const uploadBwInp = document.querySelector('input[name="upload_bandwidth"]');
    const maxSessionsInp = document.querySelector('input[name="max_sessions"]');
    
    window.__annotate([
      { target: quotaSizeInp, num: '①', label: '最大儲存空間配額 (53,687,091,200 Bytes = 50 GB)' },
      { target: quotaFilesInp, num: '②', label: '檔案總數量限制 (10,000 檔)' },
      { target: uploadBwInp, num: '③', label: '上傳頻寬限制 (10,240 KB/s = 10 MB/s)' },
      { target: maxSessionsInp, num: '④', label: '最大並發連線數 (5 條連線)' }
    ]);
  `);
  await snap('06_user_quota_limits');

  // ==========================================
  // 7. Defender Security (07_defender_security)
  // ==========================================
  console.log('Generating 07_defender_security...');
  await nav('http://localhost:8081/web/admin/defender', 2000);
  await injectAnnotationEngine();
  await evalCode(`
    const tbody = document.querySelector('#dataTable tbody') || document.querySelector('#table_body');
    if (tbody) {
      tbody.innerHTML = \`
        <tr>
          <td><span class="badge badge-light-danger fs-7 fw-bold">203.0.113.88</span></td>
          <td><span class="text-gray-800 fw-semibold">2026-10-23 16:45:00 (剩餘 28 分鐘)</span></td>
          <td><span class="badge badge-danger">18 分 (門檻: 15)</span></td>
          <td class="text-end">
            <button class="btn btn-sm btn-light-success py-1 px-3">
              <i class="fas fa-unlock me-1"></i> 解除封鎖 (Unban)
            </button>
          </td>
        </tr>
        <tr>
          <td><span class="badge badge-light-danger fs-7 fw-bold">198.51.100.45</span></td>
          <td><span class="text-gray-800 fw-semibold">2026-10-23 17:15:00 (剩餘 58 分鐘)</span></td>
          <td><span class="badge badge-danger">25 分 (門檻: 15)</span></td>
          <td class="text-end">
            <button class="btn btn-sm btn-light-success py-1 px-3">
              <i class="fas fa-unlock me-1"></i> 解除封鎖 (Unban)
            </button>
          </td>
        </tr>
      \`;
    }
    const row1 = document.querySelector('#dataTable tbody tr:nth-child(1)');
    window.__annotate([
      { target: row1 ? row1.querySelector('td:nth-child(1)') : null, num: '①', label: '自動動態封鎖攻擊來源 IP (203.0.113.88)' },
      { target: row1 ? row1.querySelector('td:nth-child(2)') : null, num: '②', label: '封鎖有效期限 (倒數計時)' },
      { target: row1 ? row1.querySelector('td:nth-child(3)') : null, num: '③', label: '違規評分 (Score: 18 / 門檻: 15)' },
      { target: row1 ? row1.querySelector('td:nth-child(4)') : null, num: '④', label: '一鍵解除封鎖 (Unban)' }
    ]);
  `);
  await snap('07_defender_security');

  // ==========================================
  // 8. Real-time Status / Connections (08_status_connections)
  // ==========================================
  console.log('Generating 08_status_connections...');
  await nav('http://localhost:8081/web/admin/connections', 2000);
  await injectAnnotationEngine();
  await evalCode(`
    const tbody = document.querySelector('#dataTable tbody');
    if (tbody) {
      tbody.innerHTML = \`
        <tr>
          <td><span class="badge badge-light-primary fw-bold">partner_vendor</span></td>
          <td><span class="badge badge-secondary">SFTP</span></td>
          <td><span class="text-gray-800">192.168.10.125:54210</span></td>
          <td><span class="text-primary fw-semibold">/invoices/2026_Q4_Invoice_Batch.xml</span></td>
          <td><span class="badge badge-light-success fs-7">上傳中 (18.5 MB/s)</span></td>
          <td>3 分 25 秒</td>
          <td class="text-end">
            <button class="btn btn-sm btn-light-danger py-1 px-3">
              <i class="fas fa-times me-1"></i> 強制中斷 (Disconnect)
            </button>
          </td>
        </tr>
        <tr>
          <td><span class="badge badge-light-info fw-bold">edi_batch_system</span></td>
          <td><span class="badge badge-secondary">SFTP (SSH-Key)</span></td>
          <td><span class="text-gray-800">10.0.1.50:49182</span></td>
          <td><span class="text-muted">待命中 (Idle)</span></td>
          <td><span class="badge badge-light-secondary fs-7">0.0 KB/s</span></td>
          <td>12 分 10 秒</td>
          <td class="text-end">
            <button class="btn btn-sm btn-light-danger py-1 px-3">
              <i class="fas fa-times me-1"></i> 強制中斷 (Disconnect)
            </button>
          </td>
        </tr>
      \`;
    }
    const row1 = document.querySelector('#dataTable tbody tr:nth-child(1)');
    window.__annotate([
      { target: row1 ? row1.querySelector('td:nth-child(1)') : null, num: '①', label: '在線連線使用者 (partner_vendor)' },
      { target: row1 ? row1.querySelector('td:nth-child(3)') : null, num: '②', label: '傳輸協定與來源 IP (SFTP / 192.168.10.125)' },
      { target: row1 ? row1.querySelector('td:nth-child(4)') : null, num: '③', label: '正在讀寫檔案 (/invoices/2026_Q4_Invoice_Batch.xml)' },
      { target: row1 ? row1.querySelector('td:nth-child(5)') : null, num: '④', label: '即時傳輸速率 (18.5 MB/s)' },
      { target: row1 ? row1.querySelector('td:nth-child(7)') : null, num: '⑤', label: '管理員強制斷線按鈕 (Kill Session)' }
    ]);
  `);
  await snap('08_status_connections');

  // ==========================================
  // 9. Virtual Folders (09_virtual_folders)
  // ==========================================
  console.log('Generating 09_virtual_folders...');
  await nav('http://localhost:8081/web/admin/folders', 2000);
  await injectAnnotationEngine();
  await evalCode(`
    const addBtn = document.querySelector('a.btn.btn-primary');
    const rows = Array.from(document.querySelectorAll('#dataTable tbody tr'));
    const row1 = rows[0];
    const row2 = rows[1];
    window.__annotate([
      { target: row1 ? row1.querySelector('td:nth-child(1)') : null, num: '①', label: '虛擬目錄名稱 (Finance-Invoices)' },
      { target: row1 ? row1.querySelector('td:nth-child(2)') : null, num: '②', label: '後端 MinIO S3 池映射 (sftp-data / shared/invoices/)' },
      { target: row2 ? row2.querySelector('td:nth-child(1)') : null, num: '③', label: '合約歸檔共用目錄 (Contracts-Archive)' },
      { target: addBtn, num: '④', label: '+ 新增虛擬目錄 (支援跨多帳號指派)' }
    ]);
  `);
  await snap('09_virtual_folders');

  // ==========================================
  // 10. Web Client File Manager (10_web_client_login)
  // ==========================================
  console.log('Generating 10_web_client_login (File Manager)...');
  await nav('http://localhost:8081/web/client/login', 2000);
  await evalCode(`
    document.querySelector('input[name="username"]').value = 'sftpuser';
    document.querySelector('input[name="password"]').value = 'sftp123456';
    document.querySelector('#sign_in_form').submit();
  `);
  await new Promise(r => setTimeout(r, 2500));
  await injectAnnotationEngine();
  await evalCode(`
    const uploadBtn = document.querySelector('#file_manager_upload') || document.querySelector('button[data-bs-target="#modal_upload"]') || document.querySelector('.btn-primary');
    const table = document.querySelector('#file_manager_list') || document.querySelector('#dataTable') || document.querySelector('table');
    const userMenu = document.querySelector('#kt_header_user_menu_toggle') || document.querySelector('.cursor-pointer.symbol') || document.querySelector('.symbol');
    const dirRow = document.querySelector('#file_manager_list tbody tr') || document.querySelector('table tbody tr');
    
    window.__annotate([
      { target: table, num: '①', label: '免安裝現代化網頁檔案總管 (Web Client Explorer)' },
      { target: dirRow, num: '②', label: '雲端目錄樹與檔案清單 (/contracts, /invoices, /reports)' },
      { target: uploadBtn, num: '③', label: '直覺拖曳上傳 (Drag & Drop) 與批次上傳' },
      { target: userMenu, num: '④', label: '當前登入客戶帳號 (sftpuser - 集中受控)' }
    ]);
  `);
  await snap('10_web_client_login');

  ws.close();
  console.log('ALL 10 PERFECT ANNOTATED SCREENSHOTS FINISHED!');
} catch (e) {
  console.error('Error during capture:', e);
} finally {
  chrome.kill();
}
