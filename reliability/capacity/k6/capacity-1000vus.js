/**
 * load-test_10vusers.js — SRE Demo: Smoke Test (10 VU)
 * ─────────────────────────────────────────────────────
 * PURPOSE : First check after every reboot / nuke. ~6 min runtime.
 * PASS    : 0% failures, p95 < 500ms, all 7 checks green.
 * USAGE   : k6 run scripts/load-test_10vusers.js
 *
 * TRAFFIC SHAPE:
 *   50% Window Shoppers  — home + 2 product pages, leave
 *   40% Cart Abandoners  — browse + add to cart, leave
 *   10% Power Buyers     — full checkout flow
 *
 * WHAT TO WATCH:
 *   - All 7 checks green
 *   - 0% errors (threshold <0.1%)
 *   - p95 < 500ms
 *   - HPA stays at min replicas — smoke should NOT trigger scaling
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const P = {
  timeout: '15s',
  tags: { test: '10vu-smoke' },
};

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    { duration: '1m', target: 500 },
    { duration: '1m', target: 500 },
    { duration: '1m', target: 750 },
    { duration: '5m', target: 750 },
    { duration: '1m', target: 1000 },
    { duration: '5m', target: 1000 },
    { duration: '1m', target: 0  },
  ],
  thresholds: {
    http_req_failed:   ['rate<0.001'],
    http_req_duration: ['p(95)<500'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function think(lo, hi) { sleep(Math.random() * (hi - lo) + lo); }

export default function () {
  const persona = Math.random();

  group('session', () => {

    const home = http.get(`${BASE}/`, { ...P, tags: { ...P.tags, name: 'Home' } });
    check(home, { 'home: 200': r => r.status === 200 });
    think(1, 2);

    for (let i = 0; i < 2; i++) {
      const prod = http.get(`${BASE}/product/${pick(PRODUCTS)}`,
        { ...P, tags: { ...P.tags, name: 'ProductPage' } });
      check(prod, {
        'product: 200':       r => r.status === 200,
        'product: has price': r => r.body && r.body.includes('$'),
      });
      think(1, 2);
    }

    if (persona >= 0.5) return;

    const add = http.post(`${BASE}/cart`,
      { product_id: pick(PRODUCTS), quantity: '1' },
      { ...P, tags: { ...P.tags, name: 'AddToCart' } });
    check(add, { 'addToCart: 200 or 302': r => r.status === 200 || r.status === 302 });

    const cart = http.get(`${BASE}/cart`, { ...P, tags: { ...P.tags, name: 'ViewCart' } });
    check(cart, { 'viewCart: 200': r => r.status === 200 });
    think(1, 2);

    if (persona >= 0.1) return;

    const co = http.post(`${BASE}/cart/checkout`, {
      email:                        'sre-smoke@example.com',
      street_address:               '1 Smoke Lane',
      zip_code:                     '10001',
      city:                         'SmokeCity',
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
    think(1, 2);
  });
}
