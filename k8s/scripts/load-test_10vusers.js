/**
 * load-test_10vusers.js — SRE Demo Platform: Smoke Test (10 VU)
 * =============================================================================
 * Run this FIRST after every reboot to verify the stack is healthy before
 * running the 100 VU or 1000 VU tests. Expected runtime: ~5 minutes.
 *
 * Pass criteria (all must be green):
 *   - 0% failure rate
 *   - p95 < 500ms
 *   - All check() assertions passing
 *
 * USAGE:
 *   k6 run scripts/load-test_10vusers.js
 * =============================================================================
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';  // fallback to port-forward

const REQ_PARAMS = { timeout: '15s', tags: { test: '10vu-smoke' } };

const PRODUCTS = ['OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0'];

export const options = {
  stages: [
    { duration: '30s', target: 10  },
    { duration: '30m',  target: 10  },
    { duration: '30s', target: 0   },
  ],
  thresholds: {
    http_req_failed:   ['rate<0.001'],   // near-zero failures on smoke test
    http_req_duration: ['p(95)<500'],    // fast with 10 VU
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  group('Smoke Test', function () {
    const home = http.get(`${BASE}/`, { ...REQ_PARAMS, tags: { ...REQ_PARAMS.tags, name: 'Home' } });
    check(home, {
      'home: 200':           (r) => r.status === 200,
      'home: has products':  (r) => r.body && r.body.includes('product'),
    });
    sleep(2);

    for (const pid of PRODUCTS.slice(0, 2)) {
      const product = http.get(`${BASE}/product/${pid}`, { ...REQ_PARAMS, tags: { ...REQ_PARAMS.tags, name: 'ProductPage' } });
      check(product, { 'product: 200': (r) => r.status === 200 });
      sleep(1);
    }

    http.post(`${BASE}/cart`, { product_id: PRODUCTS[0], quantity: '1' }, {
      ...REQ_PARAMS,
      tags: { ...REQ_PARAMS.tags, name: 'AddToCart' },
    });

    const cart = http.get(`${BASE}/cart`, { ...REQ_PARAMS, tags: { ...REQ_PARAMS.tags, name: 'ViewCart' } });
    check(cart, { 'cart: 200': (r) => r.status === 200 });
    sleep(2);
  });
}
