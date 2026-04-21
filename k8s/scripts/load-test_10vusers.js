/**
 * load-test_10vusers.js — SRE Demo Platform: Smoke Test (10 VU)
 * =============================================================================
 * Run this FIRST after every reboot to verify the stack is healthy before
 * running the 100 VU or 1000 VU tests. Expected runtime: ~6 minutes.
 *
 * Pass criteria (all must be green):
 *   - <0.1% failure rate (not 0% — DNS hiccups happen; 0.1% is honest)
 *   - p95 < 500ms
 *   - All check() assertions passing
 *
 * KEY CHANGES vs v2:
 *   - Sustained stage: 30m → 5m. "Smoke test" means quick validation,
 *     not a 30-minute soak. Use load-test_100vusers.js for soak testing.
 *   - BASE_URL default: localhost:8080 (LoadBalancer, reliable on Docker Desktop)
 *     with explicit comment explaining why not 30080.
 *   - timeout: 10s → 15s on smoke test — gives cold-start responses more room.
 *   - Added checkout flow (5% of VUs) to verify the full cart→checkout→payment
 *     path on every smoke run. Previously smoke only tested browse+cart.
 *
 * USAGE:
 *   k6 run scripts/load-test_10vusers.js
 *   k6 run --env BASE_URL=http://localhost:8080 scripts/load-test_10vusers.js
 * =============================================================================
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

// LoadBalancer :8080 is the reliable path on Docker Desktop.
// NodePort :30080 is unreliable — Docker Desktop's VM network namespace
// doesn't always bind NodePorts to macOS localhost after sleep/wake.
const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const REQ_PARAMS = {
  timeout: '15s',
  tags: { test: '10vu-smoke' },
};

const PRODUCTS = ['OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0'];

export const options = {
  stages: [
    { duration: '30s', target: 10  },   // ramp up
    { duration: '5m',  target: 10  },   // smoke window (was 30m — too long)
    { duration: '30s', target: 0   },   // ramp down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.001'],   // <0.1% — honest smoke threshold
    http_req_duration: ['p(95)<500'],    // fast with 10 VU
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  group('Smoke Test', function () {

    // ── Browse ────────────────────────────────────────────────────────────────
    const home = http.get(`${BASE}/`, {
      ...REQ_PARAMS,
      tags: { ...REQ_PARAMS.tags, name: 'Home' },
    });
    check(home, {
      'home: 200':          (r) => r.status === 200,
      'home: has products': (r) => r.body && r.body.includes('product'),
    });
    sleep(2);

    for (const pid of PRODUCTS.slice(0, 2)) {
      const product = http.get(`${BASE}/product/${pid}`, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'ProductPage' },
      });
      check(product, { 'product: 200': (r) => r.status === 200 });
      sleep(1);
    }

    // ── Cart ──────────────────────────────────────────────────────────────────
    http.post(`${BASE}/cart`,
      { product_id: PRODUCTS[0], quantity: '1' },
      { ...REQ_PARAMS, tags: { ...REQ_PARAMS.tags, name: 'AddToCart' } }
    );

    const cart = http.get(`${BASE}/cart`, {
      ...REQ_PARAMS,
      tags: { ...REQ_PARAMS.tags, name: 'ViewCart' },
    });
    check(cart, { 'cart: 200': (r) => r.status === 200 });
    sleep(2);

    // ── Checkout (5% of VUs — verifies full payment path) ────────────────────
    if (Math.random() < 0.05) {
      const checkoutRes = http.post(`${BASE}/cart/checkout`, {
        email:                        'smoke-test@example.com',
        street_address:               '1 Smoke Test Lane',
        zip_code:                     '10001',
        city:                         'SmokeCity',
        state:                        'CA',
        country:                      'US',
        credit_card_number:           '4432801561520454',
        credit_card_expiration_month: '1',
        credit_card_expiration_year:  '2030',
        credit_card_cvv:              '672',
      }, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'Checkout' },
      });
      check(checkoutRes, {
        'checkout: ok':    (r) => r.status === 200 || r.status === 302,
        'checkout: no 5xx': (r) => r.status < 500,
      });
      sleep(2);
    }
  });
}
