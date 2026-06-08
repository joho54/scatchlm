// 각 .frame 요소를 정확히 1284x2778 px PNG로 렌더한다. (iPhone 6.7" 세로)
// App Store Connect iPhone 슬롯 허용 규격: 6.5"=1242x2688 또는 6.7"=1284x2778.
// 실행: node render.mjs   (출력: out/shot-1.png … shot-5.png)
import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { mkdirSync } from 'fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = join(__dirname, 'out');
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1284, height: 2778 },
  deviceScaleFactor: 1,            // 1배 = App Store 6.7" 규격 그대로
});

await page.goto('file://' + join(__dirname, 'screenshots.html'));
await page.waitForLoadState('networkidle');

// 미리보기는 가로 캐러셀(zoom 축소). 렌더 시엔 풀사이즈 1:1로 되돌린다.
await page.evaluate(() => document.body.classList.add('rendering'));

const ids = ['shot-1', 'shot-2', 'shot-3', 'shot-4', 'shot-5'];
for (const id of ids) {
  const el = page.locator('#' + id);
  await el.screenshot({ path: join(outDir, id + '.png') });
  console.log('✓', id + '.png');
}

await browser.close();
console.log('\n완료 → out/  (1284×2778, App Store iPhone 6.7" 세로 업로드용)');
