// node shots.mjs shoot <label>   → shots/<label>.png (full page, gitignored) + img/<label>.jpg (1280×720 view, committed)
// node shots.mjs diff <a> <b>     → pixel diff of two full-page shots; exits 1 above MAX_DIFF_PCT
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';

// A rescued site must look like the healthy baseline. Re-renders of the same page measured 0.000 %; a missing
// section, a raw [shortcode] or a spam line shows up as several % or a height change (which fails outright).
const MAX_DIFF_PCT = 0.5;
const SITE = 'http://localhost:8092/';
const dir = (p) => new URL(p, import.meta.url).pathname;
const SHOTS = dir('shots/'), IMG = dir('img/');

async function shoot(label) {
  const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_PATH || 'playwright');
  mkdirSync(SHOTS, { recursive: true }); mkdirSync(IMG, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
  const res = await page.goto(SITE, { waitUntil: 'networkidle', timeout: 60_000 });
  await page.evaluate(async () => {  // scroll the whole page so lazy images load, then back to the top
    for (let y = 0; y < document.body.scrollHeight; y += 400) { scrollTo(0, y); await new Promise((r) => setTimeout(r, 50)); }
    scrollTo(0, 0);
  });
  await page.addStyleTag({ content: '*,*::before,*::after{transition:none!important;animation:none!important;caret-color:transparent!important}' });
  await page.evaluate(async () => {
    await Promise.all([...document.images].map((i) => i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; })));
    await document.fonts.ready;
  });
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${SHOTS}${label}.png`, fullPage: true });
  // The hacked incident's visible symptom is in the footer, so both of its shots show the bottom of the page.
  if (label.startsWith('hacked')) await page.evaluate(() => scrollTo(0, document.body.scrollHeight));
  if (label !== 'baseline') await page.screenshot({ path: `${IMG}${label}.jpg`, type: 'jpeg', quality: 80 });
  console.log(`[shots] ${label}: HTTP ${res.status()}`);
  await browser.close();
}

function diff(a, b) {
  const [fa, fb] = [`${SHOTS}${a}.png`, `${SHOTS}${b}.png`];
  const size = (f) => spawnSync('magick', ['identify', '-format', '%w %h', f], { encoding: 'utf8' }).stdout.trim();
  const [sa, sb] = [size(fa), size(fb)];
  if (sa !== sb) { console.log(`[shots] FAIL ${a} vs ${b}: page size changed ${sa} → ${sb}`); process.exit(1); }
  const r = spawnSync('magick', ['compare', '-metric', 'AE', '-fuzz', '10%', fa, fb, 'null:'], { encoding: 'utf8' });
  const ae = parseFloat(r.stderr.match(/\(([\d.e+]+)\)/)?.[1] ?? r.stderr);  // IM 7 prints "<quantum-scaled> (<pixel count>)"
  if (r.status > 1 || Number.isNaN(ae)) throw new Error(`magick compare failed: ${r.stderr}`);
  const [w, h] = sa.split(' ').map(Number), pct = (100 * ae) / (w * h);
  const ok = pct <= MAX_DIFF_PCT;
  console.log(`[shots] ${ok ? 'ok  ' : 'FAIL'} ${b} vs ${a}: ${pct.toFixed(3)}% of ${w}×${h} px differ (≤ ${MAX_DIFF_PCT}%)`);
  if (!ok) process.exit(1);
}

const [cmd, a, b] = process.argv.slice(2);
const label = /^[\w-]+$/;
if (cmd === 'shoot' && label.test(a ?? '')) await shoot(a);
else if (cmd === 'diff' && label.test(a ?? '') && label.test(b ?? '')) diff(a, b);
else { console.error('usage: node shots.mjs shoot <label> | diff <a> <b>'); process.exit(2); }
