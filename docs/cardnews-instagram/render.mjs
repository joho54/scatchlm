// 각 .card 요소를 1080x1350 px PNG로 렌더한다. (인스타/스레드 캐러셀 4:5)
// 실행: node render.mjs   (출력: out/card-1.png … card-7.png)
import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { mkdirSync } from 'fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = join(__dirname, 'out');
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1080, height: 1350 },
  deviceScaleFactor: 2,            // 2배 = 2160x2700, 인스타 업로드 시 선명
});

await page.goto('file://' + join(__dirname, 'cardnews.html'));
await page.waitForLoadState('networkidle');
await page.evaluate(() => document.body.classList.add('rendering'));

const N = 7;
for (let i = 1; i <= N; i++) {
  const el = page.locator('#card-' + i);
  await el.screenshot({ path: join(outDir, 'card-' + i + '.png') });
  console.log('✓ card-' + i + '.png');
}

await browser.close();
console.log('\n완료 → out/  (7장 · 1080×1350@2x · 인스타/스레드 캐러셀 업로드용)');
