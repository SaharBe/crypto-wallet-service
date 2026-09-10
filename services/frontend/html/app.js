/* Crypto Wallet Console — vanilla SPA.
 *
 * All backend calls are same-origin and proxied by NGINX:
 *   /api/wallet/*  ->  wallet-service:3000/*
 *   /api/order/*   ->  order-service:3000/*
 * so the browser never makes a cross-origin request and CORS never applies.
 */

const API = {
  walletHealth: "/api/wallet/health",
  walletRoot: "/api/wallet/",
  walletBalance: (u) => `/api/wallet/balance/${encodeURIComponent(u)}`,
  orderHealth: "/api/order/health",
  orderRoot: "/api/order/",
  orders: "/api/order/orders",
  frontendHealth: "/healthz",
};

const LS = { user: "cwc.userId", orders: "cwc.orders" };
const $ = (sel, root = document) => root.querySelector(sel);

/* ── helpers ─────────────────────────────────────────────── */

async function timedFetch(url, opts = {}) {
  const started = performance.now();
  try {
    const res = await fetch(url, { headers: { Accept: "application/json" }, ...opts });
    const ms = Math.round(performance.now() - started);
    let body = null;
    try { body = await res.json(); } catch (_) { /* non-JSON / empty */ }
    return { ok: res.ok, status: res.status, body, ms };
  } catch (err) {
    return { ok: false, status: 0, body: null, ms: Math.round(performance.now() - started), error: err.message };
  }
}

const fmtTime = (d = new Date()) => d.toLocaleTimeString([], { hour12: false });

function setHealthRow(svc, state, detail, ms) {
  const li = $(`.health-list li[data-svc="${svc}"]`);
  if (!li) return;
  $(".dot", li).className = `dot dot-${state}`;
  $(".svc-detail", li).textContent = detail;
  $(".svc-latency", li).textContent = ms != null ? `${ms} ms` : "";
}

/* ── system health ───────────────────────────────────────── */

async function refreshHealth() {
  $("#health-updated").textContent = `checked ${fmtTime()}`;

  const front = await timedFetch(API.frontendHealth);
  setHealthRow("frontend", front.ok ? "up" : "down",
    front.ok ? "serving static SPA" : (front.error || `HTTP ${front.status}`), front.ms);

  const wHealth = await timedFetch(API.walletHealth);
  if (wHealth.ok) {
    const wRoot = await timedFetch(API.walletRoot);
    const db = wRoot.body && wRoot.body.database;
    const degraded = db && db !== "connected";
    setHealthRow("wallet", degraded ? "degraded" : "up",
      db ? `DB ${db}` : "UP", wHealth.ms);
  } else {
    setHealthRow("wallet", "down", wHealth.error || `HTTP ${wHealth.status}`, wHealth.ms);
  }

  const oHealth = await timedFetch(API.orderHealth);
  if (oHealth.ok) {
    const oRoot = await timedFetch(API.orderRoot);
    const status = oRoot.body && (oRoot.body.status || oRoot.body.message);
    setHealthRow("order", "up", status ? String(status) : "UP", oHealth.ms);
  } else {
    setHealthRow("order", "down", oHealth.error || `HTTP ${oHealth.status}`, oHealth.ms);
  }
}

/* ── wallet balances ─────────────────────────────────────── */

async function loadBalances(userId) {
  const body = $("#balance-body");
  if (!userId) {
    body.innerHTML = '<p class="empty">Enter a user ID to view balances.</p>';
    return;
  }
  const res = await timedFetch(API.walletBalance(userId));
  $("#balance-updated").textContent = `${fmtTime()} · ${res.ms} ms`;

  if (!res.ok) {
    body.innerHTML = `<p class="empty">Error loading balances (HTTP ${res.status}${res.error ? ` — ${res.error}` : ""}).</p>`;
    return;
  }
  const rows = (res.body && res.body.balances) || [];
  if (rows.length === 0) {
    body.innerHTML = `<p class="empty">No balances found for <code>${escapeHtml(userId)}</code>.</p>`;
    return;
  }
  body.innerHTML = `
    <table>
      <thead><tr><th>Coin</th><th class="num">Amount</th></tr></thead>
      <tbody>
        ${rows.map((r) => `
          <tr>
            <td>${escapeHtml(String(r.coin ?? r.currency ?? "—"))}</td>
            <td class="num">${escapeHtml(String(r.amount ?? r.balance ?? "0"))}</td>
          </tr>`).join("")}
      </tbody>
    </table>`;
}

/* ── orders ──────────────────────────────────────────────── */

function readOrders() {
  try { return JSON.parse(localStorage.getItem(LS.orders) || "[]"); }
  catch (_) { return []; }
}
function writeOrders(list) {
  try { localStorage.setItem(LS.orders, JSON.stringify(list.slice(0, 25))); } catch (_) {}
}

function renderOrders() {
  const body = $("#orders-body");
  const list = readOrders();
  if (list.length === 0) {
    body.innerHTML = '<p class="empty">No orders submitted yet.</p>';
    return;
  }
  body.innerHTML = `
    <table>
      <thead><tr><th>Time</th><th>User</th><th>Action</th><th class="num">Amount</th><th>Coin</th><th>Status</th></tr></thead>
      <tbody>
        ${list.map((o) => `
          <tr>
            <td>${escapeHtml(o.time)}</td>
            <td>${escapeHtml(o.userId)}</td>
            <td><span class="tag tag-${o.action}">${escapeHtml(o.action)}</span></td>
            <td class="num">${escapeHtml(String(o.amount))}</td>
            <td>${escapeHtml(o.coin)}</td>
            <td><span class="tag tag-${o.status}">${escapeHtml(o.status)}</span></td>
          </tr>`).join("")}
      </tbody>
    </table>`;
}

async function submitOrder(evt) {
  evt.preventDefault();
  const msg = $("#order-msg");
  const payload = {
    userId: $("#order-user").value.trim(),
    coin: $("#order-coin").value.trim(),
    amount: Number($("#order-amount").value),
    action: $("#order-action").value,
  };
  if (!payload.userId || !payload.coin || !(payload.amount > 0)) {
    showMsg(msg, "err", "User ID, coin and a positive amount are required.");
    return;
  }

  const res = await timedFetch(API.orders, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  const accepted = res.status === 202 || res.ok;
  const entry = {
    time: fmtTime(),
    userId: payload.userId,
    action: payload.action,
    amount: payload.amount,
    coin: payload.coin.toUpperCase(),
    status: accepted ? "accepted" : "failed",
  };
  writeOrders([entry, ...readOrders()]);
  renderOrders();

  if (accepted) {
    showMsg(msg, "ok", `Order accepted (HTTP ${res.status}) — processing asynchronously via Kafka.`);
    // Reflect the async balance update once the consumer has caught up.
    $("#balance-user").value = payload.userId;
    localStorage.setItem(LS.user, payload.userId);
    setTimeout(() => loadBalances(payload.userId), 2500);
  } else {
    const detail = (res.body && (res.body.error || res.body.message)) || res.error || `HTTP ${res.status}`;
    showMsg(msg, "err", `Order rejected — ${detail}`);
  }
}

function showMsg(el, kind, text) {
  el.textContent = text;
  el.className = `form-msg ${kind}`;
  el.hidden = false;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

/* ── wiring ──────────────────────────────────────────────── */

let healthTimer = null;
let balanceTimer = null;

function setHealthAuto(on) {
  clearInterval(healthTimer);
  if (on) healthTimer = setInterval(refreshHealth, 10_000);
}
function setBalanceAuto(on) {
  clearInterval(balanceTimer);
  if (on) balanceTimer = setInterval(() => {
    const u = $("#balance-user").value.trim();
    if (u) loadBalances(u);
  }, 5_000);
}

document.addEventListener("DOMContentLoaded", () => {
  const savedUser = localStorage.getItem(LS.user) || "";
  $("#balance-user").value = savedUser;
  $("#order-user").value = savedUser;

  setInterval(() => { $("#clock").textContent = fmtTime(); }, 1000);
  $("#clock").textContent = fmtTime();

  $("#refresh-all").addEventListener("click", () => {
    refreshHealth();
    const u = $("#balance-user").value.trim();
    if (u) loadBalances(u);
  });

  $("#balance-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const u = $("#balance-user").value.trim();
    localStorage.setItem(LS.user, u);
    loadBalances(u);
  });

  $("#health-auto").addEventListener("change", (e) => setHealthAuto(e.target.checked));
  $("#balance-auto").addEventListener("change", (e) => setBalanceAuto(e.target.checked));
  $("#order-form").addEventListener("submit", submitOrder);
  $("#orders-clear").addEventListener("click", () => { writeOrders([]); renderOrders(); });

  refreshHealth();
  setHealthAuto(true);
  renderOrders();
  if (savedUser) loadBalances(savedUser);
});
