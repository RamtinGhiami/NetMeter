/* InternetMeter dashboard — vanilla JS, no build step. */
"use strict";

const FA_DIGITS = "۰۱۲۳۴۵۶۷۸۹";
const JALALI_MONTHS = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور",
  "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const state = {
  data: null,
  range: 30,
  search: "",
  selectedMac: "",
  timer: null,
  failCount: 0,
};

/* ---------------- formatting ---------------- */
function fa(value) {
  return String(value).replace(/[0-9]/g, (d) => FA_DIGITS[+d]);
}

function fmtBytes(bytes, opts) {
  const n = Number(bytes) || 0;
  const digits = (opts && opts.digits != null) ? opts.digits : 2;
  if (n < 1024) return fa(Math.round(n)) + " بایت";
  const units = ["کیلوبایت", "مگابایت", "گیگابایت", "ترابایت", "پتابایت"];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  const short = ["KB", "MB", "GB", "TB", "PB"][i];
  let shown = v >= 100 ? v.toFixed(0) : v.toFixed(digits);
  if (shown.indexOf(".") >= 0) shown = shown.replace(/0+$/, "").replace(/\.$/, "");
  return fa(shown) + " " + short;
}

function fmtRate(bps) {
  const n = Number(bps) || 0;
  if (n <= 0) return "—";
  return fmtBytes(n, { digits: 1 }) + "/ث";
}

function fmtClock(ts) {
  if (!ts) return "—";
  const d = new Date(ts * 1000);
  return fa(pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds()));
}

function pad(n) { return String(n).padStart(2, "0"); }

function timeAgo(ts) {
  if (!ts) return "—";
  const sec = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (sec < 10) return "همین حالا";
  if (sec < 60) return fa(sec) + " ثانیه پیش";
  if (sec < 3600) return fa(Math.floor(sec / 60)) + " دقیقه پیش";
  if (sec < 86400) return fa(Math.floor(sec / 3600)) + " ساعت پیش";
  return fa(Math.floor(sec / 86400)) + " روز پیش";
}

/* Gregorian -> Jalali (short label) */
function toJalali(gy, gm, gd) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  let jy, days;
  if (gy > 1600) {
    jy = 979;
    gy -= 1600;
  } else {
    jy = 0;
    gy -= 621;
  }
  const gy2 = gm > 2 ? gy + 1 : gy;
  days = 365 * gy + Math.floor((gy2 + 3) / 4) - Math.floor((gy2 + 99) / 100) +
    Math.floor((gy2 + 399) / 400) - 80 + gd + gdm[gm - 1];
  jy += 33 * Math.floor(days / 12053);
  days %= 12053;
  jy += 4 * Math.floor(days / 1461);
  days %= 1461;
  if (days > 365) {
    jy += Math.floor((days - 1) / 365);
    days = (days - 1) % 365;
  }
  let jm, jd;
  if (days < 186) {
    jm = 1 + Math.floor(days / 31);
    jd = 1 + (days % 31);
  } else {
    jm = 7 + Math.floor((days - 186) / 30);
    jd = 1 + ((days - 186) % 30);
  }
  return { jy, jm, jd };
}

function dayLabel(iso, includeYear) {
  const [y, m, d] = iso.split("-").map(Number);
  const j = toJalali(y, m, d);
  const month = JALALI_MONTHS[j.jm - 1];
  return includeYear ? `${fa(j.jd)} ${month} ${fa(j.jy)}` : `${fa(j.jd)} ${month}`;
}

/* ---------------- API ---------------- */
async function api(path, opts) {
  const res = await fetch(path, Object.assign({ headers: { "Content-Type": "application/json" } }, opts || {}));
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; } catch (_) { data = { raw: text }; }
  if (!res.ok) {
    const err = new Error(data.error || ("HTTP " + res.status));
    err.payload = data;
    throw err;
  }
  return data;
}

function toast(msg, ms) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.add("hidden"), ms || 3200);
}

/* ---------------- render ---------------- */
function render(data) {
  state.data = data;
  const cfg = data.config || {};
  const st = data.status || {};
  const router = st.router || {};

  $("#router-label").textContent = router.model
    ? `${router.model}${router.firmware ? " — نسخه " + router.firmware : ""}`
    : (cfg.router_url ? "مودم: " + cfg.router_url.replace(/^https?:\/\//, "") : "مودم شناسایی نشده");

  renderStatus(st, cfg);
  renderCards(data);
  renderDevices(data);
  renderEvents(data.events || []);
  drawMainChart();

  if (cfg.needs_setup) {
    $("#setup-banner").classList.remove("hidden");
  } else {
    $("#setup-banner").classList.add("hidden");
  }
}

function renderStatus(st, cfg) {
  const pill = $("#status-pill");
  const text = $("#status-text");
  const errBanner = $("#error-banner");
  const errText = $("#error-banner-text");
  pill.className = "pill";
  const err = st.error || "";
  const kind = st.error_kind || "";
  const blockedFor = Math.max(0, (st.blocked_until || 0) - Math.floor(Date.now() / 1000));

  if (blockedFor > 0) {
    pill.classList.add("pill-err");
    text.textContent = "ورود متوقف — " + fa(Math.ceil(blockedFor / 60)) + " دقیقه";
  } else if (st.polling) {
    pill.classList.add("pill-warn");
    text.textContent = "در حال دریافت…";
  } else if (st.connected) {
    pill.classList.add("pill-ok");
    text.textContent = "متصل — " + timeAgo(st.last_ok);
  } else if (err) {
    pill.classList.add("pill-err");
    text.textContent = "خطا در ارتباط";
  } else {
    pill.classList.add("pill-idle");
    text.textContent = "در حال اتصال…";
  }

  if (err && !st.connected) {
    errBanner.classList.remove("hidden");
    errText.textContent = describeError(err, kind);
  } else {
    errBanner.classList.add("hidden");
  }
}

function describeError(msg, kind) {
  const base = msg || "ارتباط با مودم برقرار نشد";
  if (kind === "locked") return base + " — ورود به مودم موقتاً قفل شده است.";
  if (kind === "auth") return base + " — نام کاربری/رمز را در تنظیمات بررسی کنید.";
  if (kind === "network") return base + " — کابل یا وای‌فای و آدرس مودم را بررسی کنید.";
  if (kind === "forbidden") return base + " — این حساب اجازه‌ی دیدن آمار دستگاه‌ها را ندارد.";
  if (kind === "setup") return base;
  return base;
}

function renderCards(data) {
  const t = data.totals || {};
  $("#kpi-today").textContent = fmtBytes(t.today_bytes || 0);
  $("#kpi-month").textContent = fmtBytes(t.month_bytes || 0);
  $("#kpi-total").textContent = fmtBytes(t.all_time_bytes || 0);
  $("#kpi-wan").textContent = fmtBytes(t.wan_month_bytes || 0);

  const st = data.status || {};
  $("#kpi-today-sub").textContent = st.devices_online
    ? fa(st.devices_online) + " دستگاه آنلاین از " + fa(st.devices_total || 0)
    : "همه‌ی دستگاه‌ها";

  const cfg = data.config || {};
  $("#kpi-month-sub").textContent = cfg.reset_day > 0
    ? "دوره از روز " + fa(cfg.reset_day) + " هر ماه"
    : "از ابتدای ماه شمسی";

  const quota = Number(cfg.quota_gb || 0) * Math.pow(1024, 3);
  if (quota > 0) {
    const used = Number(t.month_bytes || 0);
    const pct = Math.min(100, (used / quota) * 100);
    $("#kpi-month-sub").textContent = fa(pct.toFixed(0)) + "٪ از " + fmtBytes(quota);
  }
  const wan = st.wan || {};
  $("#kpi-wan-sub").textContent = (wan.down_rate || wan.up_rate)
    ? "هم‌اکنون " + fmtRate(wan.down_rate) + " ↓"
    : "دانلود + آپلود";
}

const DEVICE_ICONS = [
  [/iphone|ipad|phone|mobile|android/i, "📱"],
  [/laptop|notebook|macbook|thinkpad/i, "💻"],
  [/desktop|pc|windows/i, "🖥️"],
  [/tv|television|bravia|smart-tv/i, "📺"],
  [/printer/i, "🖨️"],
  [/camera|cctv|ipcam/i, "📷"],
  [/router|repeater|ap-|mesh/i, "📡"],
  [/esp|esp32|esp8266|shelly|tasmota/i, "🔌"],
  [/playstation|ps4|ps5|xbox|switch/i, "🎮"],
];

/* Categories the user can assign to a device. */
const CATEGORIES = [
  { id: "", label: "بدون دسته", icon: "🔎" },
  { id: "phone", label: "گوشی", icon: "📱" },
  { id: "tablet", label: "تبلت", icon: "📲" },
  { id: "laptop", label: "لپ‌تاپ", icon: "💻" },
  { id: "desktop", label: "کامپیوتر", icon: "🖥️" },
  { id: "tv", label: "تلویزیون", icon: "📺" },
  { id: "console", label: "کنسول بازی", icon: "🎮" },
  { id: "printer", label: "پرینتر", icon: "🖨️" },
  { id: "camera", label: "دوربین", icon: "📷" },
  { id: "iot", label: "لوازم هوشمند", icon: "🔌" },
  { id: "router", label: "شبکه", icon: "📡" },
  { id: "other", label: "سایر", icon: "📦" },
];
const CAT_MAP = new Map(CATEGORIES.map((c) => [c.id, c]));

function categoryOf(d) {
  return CAT_MAP.get((d && d.category) || "") || CAT_MAP.get("");
}

function deviceName(d) {
  if (!d) return "دستگاه";
  return (d.custom_name || "").trim() || d.display_name || d.hostname || d.vendor || "دستگاه ناشناس";
}

function deviceIcon(d) {
  const cat = d && d.category ? CAT_MAP.get(d.category) : null;
  if (cat && cat.id) return cat.icon;
  const hay = `${(d && d.custom_name) || ""} ${(d && d.hostname) || ""} ${(d && d.vendor) || ""}`;
  for (const [re, icon] of DEVICE_ICONS) if (re.test(hay)) return icon;
  return d && d.online ? "📶" : "💤";
}

function renderDevices(data) {
  const body = $("#devices-body");
  let devices = (data.devices || []).slice();
  const q = state.search.trim().toLowerCase();
  if (q) {
    devices = devices.filter((d) =>
      deviceName(d).toLowerCase().includes(q) ||
      (d.hostname || "").toLowerCase().includes(q) ||
      (d.custom_name || "").toLowerCase().includes(q) ||
      categoryOf(d).label.toLowerCase().includes(q) ||
      (d.mac || "").toLowerCase().includes(q) ||
      (d.ip || "").includes(q) ||
      (d.vendor || "").toLowerCase().includes(q));
  }
  if (!devices.length) {
    body.innerHTML = `<tr><td colspan="6" class="empty">${q ? "دستگاهی با این مشخصات پیدا نشد." : "هنوز دستگاهی ثبت نشده است."}</td></tr>`;
    return;
  }
  const totalRate = devices.reduce((a, d) => a + (d.down_rate || 0) + (d.up_rate || 0), 0);
  body.innerHTML = devices.map((d) => {
    const name = deviceName(d);
    const cat = categoryOf(d);
    const chip = d.category ? `<span class="dev-cat">${cat.icon} ${escapeHtml(cat.label)}</span>` : "";
    const sub = [d.ip || "بدون IP", d.mac].filter(Boolean).join(" · ");
    const rate = (d.down_rate || d.up_rate)
      ? `${fmtRate(d.down_rate)} ↓ / ${fmtRate(d.up_rate)} ↑`
      : "—";
    return `<tr data-mac="${escapeHtml(d.mac)}">
      <td>
        <div class="dev-name">
          <div class="dev-avatar">${deviceIcon(d)}</div>
          <div>
            <div class="dev-title">${escapeHtml(name)}${chip}${d.is_self ? '<span class="badge-self">این رایانه</span>' : ""}</div>
            <div class="dev-sub">${escapeHtml(sub)}</div>
          </div>
        </div>
      </td>
      <td><span class="online-dot ${d.online ? "on" : ""}"><i></i>${d.online ? "آنلاین" : "آفلاین"}</span></td>
      <td class="num">${fmtBytes(d.today_bytes)}</td>
      <td class="num">${fmtBytes(d.month_bytes)}</td>
      <td class="num">${fmtBytes(d.total_bytes)}</td>
      <td class="num rate">${rate}</td>
    </tr>`;
  }).join("");

  $$("#devices-body tr").forEach((tr) => {
    tr.addEventListener("click", () => openDetail(tr.dataset.mac));
  });
  const rateEl = $("#kpi-wan-sub");
  if (rateEl && totalRate > 0 && !(state.data.status && state.data.status.wan && state.data.status.wan.down_rate)) {
    rateEl.textContent = "مجموع سرعت دستگاه‌ها: " + fmtRate(totalRate);
  }
}

function renderEvents(events) {
  const ul = $("#events-list");
  if (!events.length) {
    ul.innerHTML = '<li class="muted">رویدادی ثبت نشده است.</li>';
    return;
  }
  ul.innerHTML = events.slice(0, 10).map((e) => {
    const d = new Date((e.ts || 0) * 1000);
    const stamp = fa(pad(d.getHours()) + ":" + pad(d.getMinutes())) + " · " + dayLabel(isoDay(d));
    return `<li>
      <span class="ev-level ${escapeHtml(e.level || "info")}"></span>
      <span style="flex:1">${escapeHtml(e.message || "")}</span>
      <span class="ev-time">${stamp}</span>
    </li>`;
  }).join("");
}

function isoDay(d) {
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/* ---------------- charts ---------------- */
function prepCanvas(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.clientWidth || canvas.parentElement.clientWidth || 600;
  const cssH = Number(canvas.getAttribute("height")) || 240;
  canvas.width = Math.max(1, Math.floor(cssW * dpr));
  canvas.height = Math.max(1, Math.floor(cssH * dpr));
  canvas.style.height = cssH + "px";
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w: cssW, h: cssH };
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function niceMax(value) {
  if (value <= 0) return 1;
  const exp = Math.floor(Math.log10(value));
  const base = Math.pow(10, exp);
  const mult = value / base;
  const nice = mult <= 1 ? 1 : mult <= 2 ? 2 : mult <= 5 ? 5 : 10;
  return nice * base;
}

function drawBars(canvas, rows, opts) {
  const { ctx, w, h } = prepCanvas(canvas);
  const padTop = 14, padBottom = 26, padLeft = 8, padRight = 8;
  const plotW = w - padLeft - padRight;
  const plotH = h - padTop - padBottom;
  const n = Math.max(1, rows.length);
  const gap = n > 60 ? 1 : n > 30 ? 2 : 5;
  const slot = plotW / n;
  const barW = Math.max(1, slot - gap);

  const maxVal = niceMax(Math.max(...rows.map((r) => (r.rx || 0) + (r.tx || 0)), opts.minMax || 0));

  ctx.clearRect(0, 0, w, h);

  // horizontal grid
  ctx.strokeStyle = "rgba(140,170,210,0.13)";
  ctx.fillStyle = cssVar("--muted") || "#8fa3bd";
  ctx.font = '11px "Vazirmatn","Segoe UI",Tahoma,sans-serif';
  ctx.textAlign = "left";
  ctx.textBaseline = "middle";
  const lines = 4;
  for (let i = 0; i <= lines; i++) {
    const y = padTop + (plotH * i) / lines;
    ctx.beginPath();
    ctx.moveTo(padLeft, y);
    ctx.lineTo(w - padRight, y);
    ctx.stroke();
    const v = maxVal * (1 - i / lines);
    if (i < lines) ctx.fillText(fmtBytes(v, { digits: 0 }), padLeft + 2, y - 1);
  }

  const down = cssVar("--down") || "#4f8cff";
  const up = cssVar("--up") || "#2dd4bf";

  rows.forEach((r, i) => {
    // Standard time axis: oldest at the left, newest at the right.
    const x = padLeft + i * slot + gap / 2;
    const rx = Math.max(0, r.rx || 0);
    const tx = Math.max(0, r.tx || 0);
    let y = padTop + plotH;
    const hRx = (rx / maxVal) * plotH;
    const hTx = (tx / maxVal) * plotH;
    if (hRx > 0.4) {
      ctx.fillStyle = down;
      roundRect(ctx, x, y - hRx, barW, hRx, Math.min(3, barW / 2));
      y -= hRx;
    }
    if (hTx > 0.4) {
      ctx.fillStyle = up;
      roundRect(ctx, x, y - hTx, barW, hTx, Math.min(3, barW / 2));
    }
  });

  // labels: first, middle, last
  ctx.fillStyle = cssVar("--muted") || "#8fa3bd";
  ctx.textBaseline = "top";
  const labelIdx = n <= 3 ? rows.map((_, i) => i) : [0, Math.floor((n - 1) / 2), n - 1];
  ctx.textAlign = "center";
  labelIdx.forEach((i) => {
    const r = rows[i];
    if (!r) return;
    const cx = padLeft + (i + 0.5) * slot;
    ctx.fillText(dayLabel(r.day), Math.max(30, Math.min(w - 30, cx)), padTop + plotH + 8);
  });

  canvas._rows = rows;
  canvas._geom = { padLeft, padRight, padTop, padBottom, slot, plotW, plotH, w, h };
  canvas._maxVal = maxVal;
}

function roundRect(ctx, x, y, w, h, r) {
  if (h <= 0 || w <= 0) return;
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.lineTo(x + w, y + h);
  ctx.lineTo(x, y + h);
  ctx.lineTo(x, y + r);
  ctx.arcTo(x, y, x + r, y, r);
  ctx.closePath();
  ctx.fill();
}

function chartRows() {
  const data = state.data;
  if (!data) return [];
  const hist = (data.wan_history || []).slice(-state.range);
  const out = [];
  // Fill missing days at the end so the graph ends at today.
  const today = new Date();
  const map = new Map(hist.map((r) => [r.day, r]));
  for (let i = state.range - 1; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i);
    const key = isoDay(d);
    const row = map.get(key);
    out.push({ day: key, rx: row ? row.rx : 0, tx: row ? row.tx : 0 });
  }
  return out;
}

function drawMainChart() {
  const rows = chartRows();
  const canvas = $("#main-chart");
  drawBars(canvas, rows, {});
  const total = rows.reduce((a, r) => a + (r.rx || 0) + (r.tx || 0), 0);
  const el = $("#chart-total");
  if (el) el.textContent = "جمع " + fa(rows.length) + " روز: " + fmtBytes(total);
}

function attachChartTip(canvas, tipEl) {
  canvas.addEventListener("mousemove", (ev) => {
    const rows = canvas._rows || [];
    const g = canvas._geom;
    if (!g || !rows.length) return;
    const rect = canvas.getBoundingClientRect();
    const x = ev.clientX - rect.left;
    const i = Math.min(rows.length - 1, Math.max(0, Math.floor((g.padLeft + g.plotW - x) / g.slot)));
    const r = rows[i];
    if (!r) return;
    const total = (r.rx || 0) + (r.tx || 0);
    tipEl.innerHTML = `<b>${dayLabel(r.day, true)}</b><br>
      <span style="color:${cssVar("--down")}">↓ ${fmtBytes(r.rx)}</span><br>
      <span style="color:${cssVar("--up")}">↑ ${fmtBytes(r.tx)}</span><br>
      <span class="muted">جمع: ${fmtBytes(total)}</span>`;
    tipEl.classList.remove("hidden");
    const left = rect.width - (g.padLeft + g.plotW - (i + 0.5) * g.slot);
    tipEl.style.left = Math.max(60, Math.min(rect.width - 60, left)) + "px";
    tipEl.style.top = Math.max(20, ev.clientY - rect.top - 6) + "px";
  });
  canvas.addEventListener("mouseleave", () => tipEl.classList.add("hidden"));
}

/* ---------------- device detail ---------------- */
async function openDetail(mac) {
  if (!mac) return;
  state.selectedMac = mac;
  const dev = (state.data && state.data.devices || []).find((d) => d.mac === mac);
  $("#detail-title").textContent = deviceName(dev);
  $("#detail-meta").textContent = dev
    ? [dev.ip, dev.mac, dev.vendor, dev.conn_type === "wifi" ? "وای‌فای" : dev.conn_type === "lan" ? "کابلی" : dev.conn_type]
      .filter(Boolean).join(" · ")
    : "";
  $("#inp-dev-name").value = dev ? (dev.custom_name || "") : "";
  $("#inp-dev-name").placeholder = dev && dev.hostname ? dev.hostname : "مثلاً گوشی سارا";
  $("#inp-dev-cat").value = dev ? (dev.category || "") : "";
  $("#detail-drawer").classList.remove("hidden");

  try {
    const res = await api(`/api/device/${encodeURIComponent(mac)}/history?days=30`);
    if (!res.ok) throw new Error("not found");
    const hist = res.history || [];
    const today = hist.length ? hist[hist.length - 1] : { rx: 0, tx: 0 };
    const sum = hist.reduce((a, r) => a + r.rx + r.tx, 0);
    $("#detail-stats").innerHTML = `
      <div class="stat"><span>امروز</span><b>${fmtBytes((today.rx || 0) + (today.tx || 0))}</b></div>
      <div class="stat"><span>۳۰ روز اخیر</span><b>${fmtBytes(sum)}</b></div>
      <div class="stat"><span>کل ثبت‌شده</span><b>${fmtBytes(dev ? dev.total_bytes : 0)}</b></div>
      <div class="stat"><span>سرعت فعلی</span><b>${dev && dev.down_rate ? fmtRate(dev.down_rate) + " ↓" : "—"}</b></div>`;
    drawBars($("#detail-chart"), hist.map((r) => ({ day: r.day, rx: r.rx, tx: r.tx })), {});
  } catch (err) {
    toast("تاریخچه‌ی این دستگاه در دسترس نیست");
  }
}

/* ---------------- device meta ---------------- */
function fillCategorySelect() {
  $("#inp-dev-cat").innerHTML = CATEGORIES
    .map((c) => `<option value="${c.id}">${c.icon} ${c.label}</option>`)
    .join("");
}

async function saveDeviceMeta() {
  if (!state.selectedMac) return;
  const btn = $("#btn-dev-save");
  btn.disabled = true;
  try {
    await api("/api/device/meta", {
      method: "POST",
      body: JSON.stringify({
        mac: state.selectedMac,
        name: $("#inp-dev-name").value.trim(),
        category: $("#inp-dev-cat").value,
      }),
    });
    toast("نام و دسته ذخیره شد");
    await refresh();
    const dev = (state.data && state.data.devices || []).find((d) => d.mac === state.selectedMac);
    if (dev) {
      $("#detail-title").textContent = deviceName(dev);
      $("#inp-dev-name").placeholder = dev.hostname || "نام دلخواه";
    }
  } catch (err) {
    toast("ذخیره نشد: " + err.message);
  } finally {
    btn.disabled = false;
  }
}

/* ---------------- settings ---------------- */
function openSettings() {
  const cfg = (state.data && state.data.config) || {};
  $("#inp-router").value = cfg.router_url || "";
  $("#inp-username").value = cfg.username || "admin";
  $("#inp-password").value = "";
  $("#inp-password").placeholder = cfg.password_set ? "ذخیره شده — برای تغییر وارد کنید" : "رمز مودم";
  $("#inp-interval").value = cfg.poll_interval || 10;
  $("#inp-offline").value = cfg.offline_after_min || 5;
  $("#inp-quota").value = cfg.quota_gb || 0;
  $("#inp-reset").value = cfg.reset_day || 0;
  $("#inp-port").value = cfg.port || 8787;
  $("#inp-autostart").checked = !!cfg.start_with_windows;
  $("#test-result").classList.add("hidden");
  $("#settings-drawer").classList.remove("hidden");
}

function settingsPayload() {
  const payload = {
    router_url: $("#inp-router").value.trim(),
    username: $("#inp-username").value.trim() || "admin",
    poll_interval: Number($("#inp-interval").value) || 10,
    offline_after_min: Number($("#inp-offline").value) || 5,
    quota_gb: Number($("#inp-quota").value) || 0,
    reset_day: Number($("#inp-reset").value) || 0,
    port: Number($("#inp-port").value) || 8787,
    start_with_windows: $("#inp-autostart").checked,
  };
  const pw = $("#inp-password").value;
  if (pw) payload.password = pw;
  return payload;
}

async function saveSettings(ev) {
  ev.preventDefault();
  const btn = ev.target.querySelector('button[type="submit"]');
  btn.disabled = true;
  try {
    await api("/api/config", { method: "POST", body: JSON.stringify(settingsPayload()) });
    toast("تنظیمات ذخیره شد");
    $("#inp-password").value = "";
    await refresh();
    setTimeout(() => $("#settings-drawer").classList.add("hidden"), 400);
  } catch (err) {
    toast("ذخیره نشد: " + err.message);
  } finally {
    btn.disabled = false;
  }
}

async function testConnection() {
  const btn = $("#btn-test");
  const box = $("#test-result");
  btn.disabled = true;
  box.className = "test-result";
  box.textContent = "در حال تست…";
  box.classList.remove("hidden");
  try {
    const res = await api("/api/test", { method: "POST", body: JSON.stringify(settingsPayload()) });
    box.classList.add("ok");
    const r = res.router || {};
    box.innerHTML = `اتصال موفق ✅<br>مدل: ${escapeHtml(r.model || "—")} · دستگاه‌های آنلاین: ${fa(res.hosts || 0)}
      <br><span class="muted">ترافیک ماه مودم: ${fmtBytes(((res.wan || {}).month_rx || 0) + ((res.wan || {}).month_tx || 0))}</span>`;
  } catch (err) {
    box.classList.add("bad");
    const kind = (err.payload && err.payload.kind) || "";
    box.textContent = "اتصال ناموفق: " + describeError(err.message, kind);
  } finally {
    btn.disabled = false;
  }
}

async function clearHistory() {
  if (!confirm("همه‌ی آمار مصرف پاک شود؟ این کار برگشت‌پذیر نیست.")) return;
  try {
    await api("/api/clear", { method: "POST", body: "{}" });
    toast("تاریخچه پاک شد");
    await refresh();
  } catch (err) {
    toast("پاک نشد: " + err.message);
  }
}

async function quitApp() {
  if (!confirm("برنامه بسته شود؟ پایش مصرف متوقف می‌شود.")) return;
  try {
    await api("/api/quit", { method: "POST", body: "{}" });
    clearTimeout(state.timer);
    document.body.innerHTML = '<div style="display:grid;place-items:center;height:100vh;font-family:inherit">' +
      '<p>برنامه بسته شد. برای اجرای دوباره روی میان‌بر NetMeter کلیک کنید.</p></div>';
  } catch (err) {
    toast("بسته نشد: " + err.message);
  }
}

/* ---------------- refresh loop ---------------- */
async function refresh() {
  try {
    const data = await api("/api/snapshot");
    state.failCount = 0;
    render(data);
    schedule();
  } catch (err) {
    state.failCount++;
    $("#status-pill").className = "pill pill-err";
    $("#status-text").textContent = "برنامه پاسخ نمی‌دهد";
    schedule(Math.min(30, 5 * state.failCount));
  }
}

function schedule(seconds) {
  clearTimeout(state.timer);
  const interval = Math.max(3, seconds || ((state.data && state.data.config || {}).poll_interval || 10));
  state.timer = setTimeout(refresh, interval * 1000);
}

/* ---------------- init ---------------- */
function bind() {
  fillCategorySelect();
  $("#btn-dev-save").addEventListener("click", saveDeviceMeta);
  $("#inp-dev-name").addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") { ev.preventDefault(); saveDeviceMeta(); }
  });
  $("#btn-refresh").addEventListener("click", async () => {
    const b = $("#btn-refresh");
    b.style.transform = "rotate(180deg)";
    await api("/api/poll", { method: "POST", body: "{}" }).catch(() => {});
    setTimeout(() => { b.style.transform = ""; refresh(); }, 600);
  });
  $("#btn-settings").addEventListener("click", openSettings);
  $("#btn-setup-open").addEventListener("click", openSettings);
  $("#settings-form").addEventListener("submit", saveSettings);
  $("#btn-test").addEventListener("click", testConnection);
  $("#btn-clear").addEventListener("click", clearHistory);
  $("#btn-quit").addEventListener("click", quitApp);

  $$("[data-close]").forEach((b) => b.addEventListener("click", () => {
    $("#" + b.dataset.close).classList.add("hidden");
  }));
  $$(".drawer").forEach((d) => d.addEventListener("click", (ev) => {
    if (ev.target === d) d.classList.add("hidden");
  }));

  $$("#range-seg .seg-btn").forEach((b) => b.addEventListener("click", () => {
    $$("#range-seg .seg-btn").forEach((x) => x.classList.remove("active"));
    b.classList.add("active");
    state.range = Number(b.dataset.range) || 30;
    drawMainChart();
  }));

  $("#search").addEventListener("input", (ev) => {
    state.search = ev.target.value;
    if (state.data) renderDevices(state.data);
  });

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      drawMainChart();
      if (!$("#detail-drawer").classList.contains("hidden")) {
        const canvas = $("#detail-chart");
        if (canvas._rows) drawBars(canvas, canvas._rows, {});
      }
    }, 180);
  });

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") $$(".drawer").forEach((d) => d.classList.add("hidden"));
  });

  attachChartTip($("#main-chart"), $("#chart-tip"));
}

bind();
refresh();
