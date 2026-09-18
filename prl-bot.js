/* prl-bot.js —— 在 SafeTrade 页面里运行的"我的手"（浏览器内版）
 * 为什么用它：脚本发请求会被 Cloudflare WAF 403，但你的浏览器能过（自带通行证）。
 * 用法：打开 https://safetrade.com/exchange/PRL-USDT → F12 → Console
 *       （第一次要先输入 allow pasting 回车）→ 把下面整段贴进去回车。
 * 首次会让你填 API Key / Secret（存在 safetrade.com 的 localStorage，方便下次再贴）。
 * 它会：每 60 秒拉我发布的配置，每 20 秒按配置补挂网格单；配置里 kill=true 就撤单退出。
 */
(async () => {
  if (window.__prlBotTimer) { console.log('%c[prl] 已在运行（如需重启先执行 window.__prlBotStop()）', 'color:orange'); return; }
  const CFG_URL = 'https://api.github.com/repos/psenY/prl-grid-runner/contents/config.json';
  const MARKET = 'prlusdt';
  const B = '/api/v2/peatio';

  const key = localStorage.getItem('prl_apikey') || prompt('SafeTrade API Key');
  const sec = localStorage.getItem('prl_secret') || prompt('SafeTrade API Secret');
  localStorage.setItem('prl_apikey', key); localStorage.setItem('prl_secret', sec);

  const enc = new TextEncoder();
  const hkey = await crypto.subtle.importKey('raw', enc.encode(sec), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sign = async (nonce) => {
    const buf = await crypto.subtle.sign('HMAC', hkey, enc.encode(nonce + key));
    return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
  };
  const auth = async () => {
    const nonce = Date.now().toString();
    return { 'X-Auth-Apikey': key, 'X-Auth-Nonce': nonce, 'X-Auth-Signature': await sign(nonce), 'Accept': 'application/json', 'Content-Type': 'application/json' };
  };
  const api = async (method, path, body) => {
    const r = await fetch(B + path, { method, headers: await auth(), body: body ? JSON.stringify(body) : undefined, credentials: 'include' });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch { }
    return { status: r.status, json: j, text: t.slice(0, 200) };
  };

  const state = { cfg: null, lastCycle: 0, done: {}, fills: 0, log: [] };
  const say = (...a) => { const s = new Date().toLocaleTimeString() + ' ' + a.join(' '); state.log.push(s); if (state.log.length > 200) state.log.shift(); console.log('%c[prl] ' + s, 'color:#0a0'); };

  const loadCfg = async () => {
    try {
      const r = await fetch(CFG_URL + '?t=' + Date.now(), { headers: { Accept: 'application/vnd.github.raw' }, cache: 'no-store' });
      const j = await r.json();
      const txt = j.content ? atob(j.content.replace(/\s/g, '')) : await r.text();
      state.cfg = JSON.parse(txt.startsWith('{') ? txt : txt.slice(txt.indexOf('{')));
      say('配置已更新：' + state.cfg.levels.map(l => l.side + '@' + l.price).join(' ') + ' | 停机 ' + state.cfg.stopPriceBelow);
    } catch (e) { say('配置拉取失败：' + e.message); }
  };

  const cycle = async () => {
    try {
      if (!state.cfg) await loadCfg();
      const cfg = state.cfg;
      if (cfg && cfg.kill) { await cancelAll('kill=true'); window.__prlBotStop(); return; }
      const tk = await api('GET', `/public/markets/${MARKET}/tickers`);
      const price = tk.json ? +tk.json.ticker.last : null;
      if (price && cfg.stopPriceBelow && price < cfg.stopPriceBelow) {
        say('!! 触发停机线 ' + cfg.stopPriceBelow + '（现价 ' + price + '）→ 撤单 + 清仓');
        await cancelAll('stop');
        const w = await api('GET', `/market/orders?market=${MARKET}&state=wait&limit=100`);
        const bal = await api('GET', '/account/balances');
        const prl = bal.json ? +(bal.json.find(x => x.currency === 'prl') || {}).balance : 0;
        if (prl > 0) { await api('POST', '/market/orders', { market: MARKET, side: 'sell', volume: String(prl), ord_type: 'market' }); say('已市价卖出 ' + prl + ' PRL'); }
        window.__prlBotStop(); return;
      }
      const w = await api('GET', `/market/orders?market=${MARKET}&state=wait&limit=100`);
      const waiting = Array.isArray(w.json) ? w.json : (w.json && w.json.data) || [];
      const bal = await api('GET', '/account/balances');
      const b = { prl: 0, usdt: 0 };
      if (bal.json) { b.prl = +((bal.json.find(x => x.currency === 'prl') || {}).balance || 0); b.usdt = +((bal.json.find(x => x.currency === 'usdt') || {}).balance || 0); }
      if (bal.status !== 200) { say('余额读取失败 HTTP ' + bal.status + ' ' + bal.text); }
      let placed = 0, exist = 0;
      for (const lv of (cfg ? cfg.levels : [])) {
        if (waiting.some(o => o.side === lv.side && Math.abs(+o.price - +lv.price) < 1e-8)) { exist++; continue; }
        if (waiting.length >= cfg.maxOpenOrders) { say('挂单数达上限'); break; }
        const usd = lv.price * lv.amount;
        if (cfg.maxOrderUsd && usd > cfg.maxOrderUsd) { say('跳过 ' + lv.side + '@' + lv.price + '：超单笔上限'); continue; }
        if (lv.side === 'sell' && b.prl < lv.amount) { say('跳过卖 ' + lv.price + '：PRL 不足 ' + b.prl.toFixed(2)); continue; }
        if (lv.side === 'buy' && b.usdt < usd) { say('跳过买 ' + lv.price + '：USDT 不足 ' + b.usdt.toFixed(2)); continue; }
        const r = await api('POST', '/market/orders', { market: MARKET, side: lv.side, volume: String(lv.amount), price: String(lv.price), ord_type: 'limit' });
        if (r.status === 201 || r.status === 200) { say('挂单 ' + lv.side + ' ' + lv.amount + ' @' + lv.price + ' 成功'); placed++; waiting.push({ side: lv.side, price: lv.price }); }
        else say('挂单失败 ' + lv.side + '@' + lv.price + ' HTTP ' + r.status + ' ' + r.text);
      }
      say(`价 ${price} | PRL ${b.prl.toFixed(2)} USDT ${b.usdt.toFixed(2)} | 挂单 ${waiting.length} | 新挂 ${placed} / 已有 ${exist}`);
    } catch (e) { say('本轮异常：' + e.message); }
  };

  const cancelAll = async (why) => {
    say('撤单（' + why + '）');
    const w = await api('GET', `/market/orders?market=${MARKET}&state=wait&limit=100`);
    const list = Array.isArray(w.json) ? w.json : (w.json && w.json.data) || [];
    for (const o of list) { const r = await api('POST', `/market/orders/${o.id}/cancel`, {}); say('撤 ' + o.id + ' → ' + r.status); }
  };

  window.__prlBotStop = () => { clearInterval(window.__prlBotTimer); clearInterval(window.__prlBotCfg); window.__prlBotTimer = null; console.log('%c[prl] 已停止', 'color:red'); };
  await loadCfg();
  await cycle();
  window.__prlBotTimer = setInterval(cycle, 20000);
  window.__prlBotCfg = setInterval(loadCfg, 60000);
  console.log('%c[prl] 已启动：每 20 秒补单，每 60 秒刷新配置。停止：window.__prlBotStop()', 'color:#0a0;font-weight:bold');
})();
