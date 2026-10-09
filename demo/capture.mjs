// Films the real flow headless: title → for each staged incident: a card (restore.sh + break.sh run behind it) → the
// broken site in the browser → the real rescue.sh streaming its own output → the site back. The hacked incident also shows
// the real `wp user list` and the spam link on the page first. Then incidents.html → end card.
// node capture.mjs   (needs the va-p5 stack on :8092; restores the healthy snapshot first and again at the end)
// Writes $OUT/raw.webm + $OUT/run.json (event marks in seconds since the page opened ≈ video t=0).
// rescue.sh rewrites logs/*.json on every run: the committed logs stay the official numbers, so `git checkout -- logs` after.
import { createRequire } from "node:module";
import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_PATH || "playwright");

const OUT = process.env.OUT || "/tmp/va-p5-demo";
const SITE = "http://localhost:8092/";
const SIZE = { width: 1280, height: 720 };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const here = new URL(".", import.meta.url).pathname;
const proj = here + "../";
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const sh = (cmd, ...args) => execFileSync(proj + cmd, args, { cwd: proj, encoding: "utf8" });

const css = `body{margin:0;height:100vh;background:#0f1d29;color:#e8eef3;font:18px -apple-system,Segoe UI,Roboto,sans-serif;overflow:hidden}`;
const card = (eyebrow, title, sub, tone = "#7fd3da") => `<!doctype html><meta charset="utf-8"><style>${css}
  body{display:grid;place-items:center;text-align:center}
  .e{letter-spacing:.18em;text-transform:uppercase;color:${tone};font-size:15px;font-weight:600} h1{font-size:50px;margin:14px 0 12px;line-height:1.15} p{color:#b9c8d4;margin:0}
  .bar{height:3px;width:0;margin:22px auto 0;background:${tone};animation:g 6s linear forwards} @keyframes g{to{width:320px}}
  code{font:16px ui-monospace,Menlo,monospace;color:#e8eef3;background:#1b2b3a;padding:3px 8px;border-radius:6px}
  </style><div><div class="e">${eyebrow}</div><h1>${title}</h1><p>${sub}</p><div class="bar"></div></div>`;

const term = (title, cmd, sim) => `<!doctype html><meta charset="utf-8"><style>${css}
  body{background:#0b1117}
  .win{position:absolute;left:90px;top:104px;width:1100px;height:470px;background:#0d1520;border:1px solid #233243;border-radius:12px;overflow:hidden;box-shadow:0 20px 50px rgba(0,0,0,.5)}
  .bar{height:38px;background:#16212d;display:flex;align-items:center;padding:0 16px;gap:8px;color:#9fb3c3;font:600 14px ui-monospace,Menlo,monospace}
  .bar i{width:12px;height:12px;border-radius:50%;display:inline-block} .bar span{margin-left:12px} #el{margin-left:auto;color:#7fd3da}
  .sim{background:#c0392b;color:#fff;border-radius:999px;padding:2px 10px;font-size:12px;letter-spacing:.06em}
  #log{padding:14px 20px;font:15px/1.55 ui-monospace,Menlo,monospace;white-space:pre-wrap;height:432px;box-sizing:border-box;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end}
  .p{color:#7fd3da} .s{color:#fff} .s b{color:#7fd3da} .ok{color:#5fd38d} .done{color:#5fd38d;font-weight:700} .x{color:#c9d6e0}
  </style><div class="win"><div class="bar"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i>
  <span>${title}</span>${sim ? '<span class="sim">SIMULATION</span>' : ""}<b id="el"></b></div><div id="log"><div><span class="p">~/p5-site-rescue $</span> ${esc(cmd)}</div></div></div>`;

// The card's growing bar keeps frames coming: a page that never repaints gives the recorder no first frame, and the
// video then starts late (seen: a 6 s offset when the opening card was fully static).
// Visible cursor + ring (Playwright's mouse is invisible on video), and a label pill on the real site. All pointer-events:none,
// all on <html> so a zoomed <body> (the error pages) does not scale their coordinates.
const overlayJs = (label) => {
  if (!document.getElementById("__cur")) {
    const mk = (id, css) => Object.assign(document.documentElement.appendChild(Object.assign(document.createElement("div"), { id })).style, { position: "fixed", pointerEvents: "none", zIndex: 2147483646, ...css });
    mk("__cur", { width: "20px", height: "20px", borderRadius: "50%", background: "rgba(20,20,20,.9)", boxShadow: "0 0 0 5px rgba(255,255,255,.85),0 3px 10px rgba(0,0,0,.4)", left: "94%", top: "88%", transition: "left .6s cubic-bezier(.4,0,.2,1),top .6s cubic-bezier(.4,0,.2,1)" });
    mk("__ring", { border: "3px solid #EF621C", borderRadius: "14px", boxShadow: "0 0 0 6px rgba(239,98,28,.18)", opacity: 0, transition: "all .5s cubic-bezier(.4,0,.2,1)" });
  }
  if (label) {
    const el = document.documentElement.appendChild(document.createElement("div"));
    Object.assign(el.style, { position: "fixed", pointerEvents: "none", zIndex: 2147483645, left: "16px", top: "52px", padding: "7px 14px", borderRadius: "999px",
      font: "600 15px -apple-system,Segoe UI,Roboto,sans-serif", color: "#fff", background: label.tone, boxShadow: "0 4px 14px rgba(0,0,0,.3)" });
    el.textContent = label.text;
  }
};
// The footer is the last thing on the page, under where the captions burn in: blank space below it lets it scroll up.
const footerUp = () => (document.body.style.paddingBottom = "220px");
async function point(page, loc, hold = 800, scroll = true) {
  if (scroll) { await page.evaluate((el) => el.scrollIntoView({ block: "center" }), await loc.elementHandle()); await wait(300); }
  const b = await loc.boundingBox();
  if (!b) throw new Error("nothing to point at: " + loc);
  await page.evaluate((b) => {
    Object.assign(document.getElementById("__cur").style, { left: b.x + b.width - 4 + "px", top: b.y + b.height - 4 + "px" });
    Object.assign(document.getElementById("__ring").style, { left: b.x - 8 + "px", top: b.y - 8 + "px", width: b.width + 10 + "px", height: b.height + 10 + "px", opacity: 1 });
  }, b);
  await wait(hold);
}

// The real site in the browser, with a pill naming what it is (URL + the status the browser actually got).
async function browse(page, key, label, tone, sel, hold = 1500) {
  const res = await page.goto(SITE, { waitUntil: "load" });
  const status = res.status();
  // WordPress's error page is 14 px text at the top: magnified (and moved clear of the pill) so it reads at 720p.
  if (status !== 200) await page.evaluate(() => Object.assign(document.body.style, { zoom: 1.5, marginTop: "80px" }));
  await page.evaluate(overlayJs, { text: `localhost:8092 · HTTP ${status} · ${label}`, tone });
  mark(key); run.http[key] = status;
  await point(page, page.locator(sel).first(), hold);
  return status;
}

// Any script, spawned for real; every line it prints goes into the terminal page as it arrives. `[t+…s]` lines are marked.
function stream(page, cmd, args, key) {
  return new Promise((resolve, reject) => {
    const p = spawn(proj + cmd, args, { cwd: proj, stdio: ["ignore", "pipe", "pipe"] });
    const lines = [], steps = [];
    let buf = "";
    p.stdout.on("data", (d) => {
      buf += d; let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trimEnd(); buf = buf.slice(i + 1);
        if (!line) continue;
        lines.push(line);
        const st = /^(\[t\+[\d.]+s\] [^:]+:)(.*)$/.exec(line);
        if (st) steps.push(+((Date.now() - t0) / 1000).toFixed(2));
        if (/^\[rescue\] .* fixed in/.test(line)) mark(key + "Done");
        const html = st ? `<b>${esc(st[1])}</b>${esc(st[2])}` : esc(line);
        const c = st ? "s" : /^\s*✓/.test(line) ? "ok" : /^\[rescue\]/.test(line) ? "done" : "x";
        page.evaluate(([h, c]) => { const el = document.createElement("div"); el.className = c; el.innerHTML = h; document.getElementById("log").appendChild(el); }, [html, c]).catch(() => {});
      }
    });
    let err = ""; p.stderr.on("data", (d) => (err += d));
    p.on("error", reject);
    p.on("close", (code) => (code === 0 ? resolve({ lines, steps }) : reject(new Error(`${cmd} ${args} exited ${code}\n${lines.slice(-5).join("\n")}\n${err}`))));
  });
}

async function rescue(page, inc, title, sim) {
  await page.setContent(term(`p5-site-rescue — the real rescue.sh, live`, `./rescue.sh ${inc}`, sim)); mark("r" + inc);
  await page.evaluate(() => { const t = performance.now(), el = document.getElementById("el"); window.__tick = setInterval(() => (el.textContent = ((performance.now() - t) / 1000).toFixed(1) + " s"), 100); });
  const { lines, steps } = await stream(page, "rescue.sh", [inc], "r" + inc);
  await page.evaluate(() => { clearInterval(window.__tick); document.getElementById("el").textContent += " ✓"; });
  const done = lines.find((l) => /^\[rescue\] .* fixed in/.test(l));
  if (!done) throw new Error(inc + ": rescue.sh never printed fixed in");
  run.rescues[inc] = { fixed_in_s: +/fixed in ([\d.]+) s/.exec(done)[1], steps, log: lines };
  await wait(1500);
}

// restore.sh + break.sh run behind the card (that wait is never filmed: the card is static, assemble keeps ~2 s of it).
async function stage(page, key, n, title, sub, tone) {
  await page.setContent(card(`Incident ${n} of 3 · staged`, title, sub, tone)); mark("s" + key);
  sh("restore.sh"); sh("break.sh", key);
  mark("c" + key); await wait(2500);
}

let browser, ctx, t0;
const run = { marks: {}, http: {}, rescues: {} };
const mark = (k) => (run.marks[k] = +((Date.now() - t0) / 1000).toFixed(2));
try {
  console.error("restore.sh → healthy site"); sh("restore.sh");
  mkdirSync(OUT + "/raw", { recursive: true });
  browser = await chromium.launch({ headless: true });
  ctx = await browser.newContext({ viewport: SIZE, deviceScaleFactor: 1, reducedMotion: "reduce", recordVideo: { dir: OUT + "/raw", size: SIZE } });
  const page = await ctx.newPage();
  t0 = Date.now();

  await page.setContent(card("Bayview Dental · a demo WordPress site", "Site down → site back", "WordPress rescue · three staged incidents, fixed live by one script"));
  mark("title"); await wait(6000);

  // 1 · white screen
  await stage(page, "white-screen", 1, "White screen after a plugin update", "staged with <code>./break.sh white-screen</code>");
  if ((await browse(page, "iwhite-screen", "staged plugin update", "#c0392b", ".wp-die-message, body p")) !== 500) throw new Error("white-screen: home is not 500");
  await rescue(page, "white-screen");
  if ((await browse(page, "bwhite-screen", "after rescue.sh", "#0c8a4a", ".bd-booking", 3000)) !== 200) throw new Error("white-screen: not back");

  // 2 · maintenance
  await stage(page, "maintenance-stuck", 2, "Stuck in maintenance mode", "an update that died half-way · staged with <code>./break.sh maintenance-stuck</code>");
  if ((await browse(page, "imaintenance-stuck", "update died half-way", "#c0392b", ".wp-die-message, body h1, body p")) !== 503) throw new Error("maintenance: home is not 503");
  await rescue(page, "maintenance-stuck");
  if ((await browse(page, "bmaintenance-stuck", "after rescue.sh", "#0c8a4a", ".bd-booking", 1200)) !== 200) throw new Error("maintenance: not back");

  // 3 · hacked (simulation)
  await stage(page, "hacked", 3, "Hacked site: a staged simulation", "inert “backdoor”, spam links to example.com / example.net · <code>./break.sh hacked</code>", "#ff8a7a");
  const allow = readFileSync(proj + "admins.allow", "utf8").split(/\s+/).filter(Boolean);
  await page.setContent(term("p5-site-rescue — WP-CLI, live", "./wp user list --role=administrator --fields=user_login,user_email,user_registered", true));
  await page.evaluate(overlayJs);
  const users = await stream(page, "wp", ["user", "list", "--role=administrator", "--fields=user_login,user_email,user_registered"]);
  const rogue = users.lines.map((l) => l.split("\t")[0]).filter((u) => u && u !== "user_login" && !allow.includes(u));
  if (!rogue.length) throw new Error("hacked: no admin outside the allowlist on screen");
  await wait(400); mark("uhacked");
  await point(page, page.locator("#log div", { hasText: rogue[0] }).first(), 1800, false);
  const spam = await page.goto(SITE).then(() => page.locator("footer a[href*='example.']").count());
  if (!spam) throw new Error("hacked: no spam link in the footer");
  await page.evaluate(footerUp);
  await page.evaluate(overlayJs, { text: "SIMULATION · localhost:8092 · injected spam links (example.com)", tone: "#c0392b" });
  mark("ihacked");
  await point(page, page.locator("footer a[href*='example.']").first(), 3000);
  await rescue(page, "hacked", null, true);
  await page.goto(SITE);
  if (await page.locator("a[href*='example.']").count()) throw new Error("hacked: spam still on the page");
  await page.evaluate(footerUp);
  await page.evaluate(overlayJs, { text: "SIMULATION · localhost:8092 · after rescue.sh: no spam links", tone: "#0c8a4a" });
  mark("bhacked");
  await point(page, page.locator(".ast-footer-copyright p").first(), 1800);

  // the incident log page (committed logs = the official numbers; the run just filmed shows its own times above)
  await page.goto("file://" + proj + "incidents.html", { waitUntil: "load" });
  await page.evaluate(overlayJs); mark("log"); await wait(800);
  for (const id of ["white-screen", "maintenance-stuck", "hacked"]) await point(page, page.locator(`#${id} header`), 1500);

  await page.setContent(card("Built by", "McKeen Asma", "WordPress &amp; Tech VA · WP-CLI + shell, no clicking around")); mark("end"); await wait(5000);
  mark("stop");
} catch (e) { run.error = String(e.stack || e); console.error(e); process.exitCode = 1; }
finally {
  const v = ctx && ctx.pages()[0]?.video();
  await ctx?.close(); await browser?.close(); // close is what writes the webm
  if (v) renameSync(await v.path(), OUT + "/raw.webm");
  writeFileSync(OUT + "/run.json", JSON.stringify(run, null, 2));
  console.log(JSON.stringify({ marks: run.marks, http: run.http, fixed: Object.fromEntries(Object.entries(run.rescues).map(([k, r]) => [k, r.fixed_in_s])), error: run.error }, null, 2));
  try { sh("restore.sh"); } catch (e) { console.error("restore.sh failed — site may be left broken", e); process.exitCode = 1; }
}
