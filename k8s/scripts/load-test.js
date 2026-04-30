/**
 * load-test.js — SRE Demo: Unified Parametric Load Test
 * ──────────────────────────────────────────────────────
 * Replaces: load-test_10vusers.js, load-test_100vusers.js,
 *           load-test_500vusers.js, load-test_1000vusers.js,
 *           load-test_10vusers_2hrs.js, load-test_500vusers_soak.js
 *
 * USAGE (all flags optional — defaults to 10 VU smoke test):
 *
 *   k6 run load-test.js
 *   k6 run load-test.js -e VUS=100
 *   k6 run load-test.js -e VUS=500 -e RAMP_UP=2m -e HOLD=10m -e RAMP_DOWN=2m
 *   k6 run load-test.js -e VUS=1000 -e RAMP_UP=5m -e HOLD=20m -e RAMP_DOWN=3m -e SPIKE_VUS=1500 -e SPIKE_DUR=30s
 *
 * ENV VARS:
 *   VUS          — peak virtual users            (default: 10)
 *   RAMP_UP      — ramp-up duration              (default: 30s)
 *   HOLD         — hold at peak duration         (default: 5m)
 *   RAMP_DOWN    — ramp-down duration            (default: 30s)
 *   SPIKE_VUS    — spike peak VUs (optional)     (default: 0 = disabled)
 *   SPIKE_DUR    — spike hold duration           (default: 30s)
 *   BASE_URL     — target base URL               (default: http://localhost:8080)
 *   P95_SLA      — p95 latency SLA in ms         (default: auto-scaled by VUS)
 *
 * TRAFFIC SHAPE (same across all test sizes):
 *   50% Window Shoppers  — home + 2 product pages, leave
 *   40% Cart Abandoners  — browse + add to cart, leave
 *   10% Power Buyers     — full checkout flow
 *
 * THRESHOLDS (auto-scaled by VUS if P95_SLA not set):
 *    <=  10 VU  -> p95 < 250 ms
 *    <= 100 VU  -> p95 < 500 ms
 *    <= 500 VU  -> p95 < 750 ms
 *    >  500 VU  -> p95 < 1000 ms
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

// ── Config ───────────────────────────────────────────────────────────────────

const BASE    = __ENV.BASE_URL     || 'http://localhost:8080';
const VUS     = parseInt(__ENV.VUS      || '10',  10);
const RAMP_UP = __ENV.RAMP_UP          || '30s';
const HOLD    = __ENV.HOLD             || '5m';
const RAMP_DN = __ENV.RAMP_DOWN        || '30s';
const SPIKE   = parseInt(__ENV.SPIKE_VUS || '0', 10);
const SPIKE_D = __ENV.SPIKE_DUR        || '30s';

// Auto-scale p95 SLA unless caller overrides
function autoP95() {
  if (VUS <= 10)  return 250;
  if (VUS <= 100) return 500;
  if (VUS <= 500) return 750;
  return 1000;
}
const P95_SLA = parseInt(__ENV.P95_SLA || String(autoP95()), 10);

// ── Stage builder ─────────────────────────────────────────────────────────────

function buildStages() {
  const stages = [
    { duration: RAMP_UP, target: VUS },
    { duration: HOLD,    target: VUS },
  ];

  if (SPIKE > 0) {
    stages.push({ duration: SPIKE_D, target: SPIKE }); // spike up
    stages.push({ duration: SPIKE_D, target: VUS   }); // spike recover
    stages.push({ duration: HOLD,    target: VUS   }); // post-spike hold
  }

  stages.push({ duration: RAMP_DN, target: 0 });
  return stages;
}

// ── Test label (shows up in Grafana tags and summary) ─────────────────────────

const testLabel = (() => {
  let s = VUS + 'vu_ramp' + RAMP_UP + '_hold' + HOLD + '_down' + RAMP_DN;
  if (SPIKE > 0) s += '_spike' + SPIKE + 'vu_' + SPIKE_D;
  return s;
})();

// ── k6 options ────────────────────────────────────────────────────────────────

export const options = {
  stages: buildStages(),
  thresholds: {
    http_req_failed:                ['rate<0.001'],
    http_req_duration:              ['p(95)<' + P95_SLA],
    'http_req_duration{name:Home}': ['p(95)<' + P95_SLA],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  tags: { test: testLabel },
};

// ── Helpers ───────────────────────────────────────────────────────────────────

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

const P = {
  timeout: '15s',
  tags: { test: testLabel },
};

function pick(arr)     { return arr[Math.floor(Math.random() * arr.length)]; }
function think(lo, hi) { sleep(Math.random() * (hi - lo) + lo); }

// Scale think time down at high VU counts to avoid artificial pacing bottleneck
function thinkScaled(lo, hi) {
  const factor = VUS > 500 ? 0.5 : VUS > 100 ? 0.75 : 1.0;
  think(lo * factor, hi * factor);
}

// ── Traffic personas ──────────────────────────────────────────────────────────

function windowShopper() {
  const home = http.get(BASE + '/', { ...P, tags: { ...P.tags, name: 'Home' } });
  check(home, { 'home: 200': r => r.status === 200 });
  thinkScaled(2, 5);

  for (let i = 0; i < 2; i++) {
    const prod = http.get(BASE + '/product/' + pick(PRODUCTS),
      { ...P, tags: { ...P.tags, name: 'ProductPage' } });
    check(prod, {
      'product: 200':       r => r.status === 200,
      'product: has price': r => r.body && r.body.includes('$'),
    });
    thinkScaled(2, 5);
  }
}

function cartAbandoner() {
  windowShopper();

  const add = http.post(BASE + '/cart',
    { product_id: pick(PRODUCTS), quantity: '1' },
    { ...P, tags: { ...P.tags, name: 'AddToCart' } });
  check(add, { 'addToCart: 200 or 302': r => r.status === 200 || r.status === 302 });

  const cart = http.get(BASE + '/cart', { ...P, tags: { ...P.tags, name: 'ViewCart' } });
  check(cart, { 'viewCart: 200': r => r.status === 200 });
  thinkScaled(2, 5);
}

function powerBuyer() {
  cartAbandoner();

  const co = http.post(BASE + '/cart/checkout', {
    email:                        'sre-load@example.com',
    street_address:               '1 Load Lane',
    zip_code:                     '10001',
    city:                         'LoadCity',
    state:                        'CA',
    country:                      'US',
    credit_card_number:           '4432801561520454',
    credit_card_expiration_month: '1',
    credit_card_expiration_year:  '2030',
    credit_card_cvv:              '672',
  }, { ...P, tags: { ...P.tags, name: 'Checkout' } });
  check(co, {
    'checkout: ok':     r => r.status === 200 || r.status === 302,
    'checkout: no 5xx': r => r.status < 500,
  });
  thinkScaled(2, 5);
}

// ── Main VU loop ──────────────────────────────────────────────────────────────

export default function () {
  const roll = Math.random();
  group('session', () => {
    if (roll < 0.50) {
      windowShopper();   // 50%
    } else if (roll < 0.90) {
      cartAbandoner();   // 40%
    } else {
      powerBuyer();      // 10%
    }
  });
}

// ── Custom end-of-test summary ────────────────────────────────────────────────

export function handleSummary(data) {
  const p95  = data.metrics['http_req_duration']?.values?.['p(95)'] ?? 'n/a';
  const rps  = data.metrics['http_reqs']?.values?.rate              ?? 'n/a';
  const errs = data.metrics['http_req_failed']?.values?.rate        ?? 'n/a';

  const pad  = (s, n) => String(s).padEnd(n);
  const fms  = v => typeof v === 'number' ? v.toFixed(1) + ' ms' : v;
  const frps = v => typeof v === 'number' ? v.toFixed(1) + ' req/s' : v;
  const fpct = v => typeof v === 'number' ? (v * 100).toFixed(3) + '%' : v;

  var spikeRow = SPIKE > 0 ? ('| Spike   : ' + pad(SPIKE + ' VU x ' + SPIKE_D, 42) + '|\n') : '';
  console.log(
    '\n+------------------------------------------------------+\n' +
    '| LOAD TEST SUMMARY                                    |\n' +
    '+------------------------------------------------------+\n' +
    '| Config  : ' + pad(testLabel, 42) + '|\n' +
    '| Peak VUs: ' + pad(VUS, 42)       + '|\n' +
    '| Ramp Up : ' + pad(RAMP_UP, 42)   + '|\n' +
    '| Hold    : ' + pad(HOLD, 42)       + '|\n' +
    '| Ramp Dn : ' + pad(RAMP_DN, 42)   + '|\n' +
    spikeRow +
    '+------------------------------------------------------+\n' +
    '| p95 lat : ' + pad(fms(p95), 42)        + '|\n' +
    '| p95 SLA : ' + pad(P95_SLA + ' ms', 42) + '|\n' +
    '| Req/s   : ' + pad(frps(rps), 42)       + '|\n' +
    '| Errors  : ' + pad(fpct(errs), 42)      + '|\n' +
    '+------------------------------------------------------+'
  );

  return { stdout: '' };
}
