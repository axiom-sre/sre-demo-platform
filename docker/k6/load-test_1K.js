import http from 'k6/http';
import { sleep, check } from 'k6';

// ── Config ────────────────────────────────────────────────────────────────────
const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0',
  '2ZYFJ3GM2N', 'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

const CURRENCIES = ['USD', 'EUR', 'GBP', 'JPY', 'CAD'];

// ── Helpers (no k6/data imports — plain JS) ───────────────────────────────────
function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function rand(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

const PARAMS = {
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  redirects: 5,   // follow redirects — fixes the null response crash
  timeout: '15s',
};

function get(path, tag) {
  const res = http.get(`${BASE}${path}`, { ...PARAMS, tags: { flow: tag } });
  check(res, { [`${tag} ok`]: r => r.status >= 200 && r.status < 400 });
  return res;
}

function post(path, body, tag) {
  const res = http.post(`${BASE}${path}`, body, { ...PARAMS, tags: { flow: tag } });
  check(res, { [`${tag} ok`]: r => r.status >= 200 && r.status < 400 });
  return res;
}

// ── Load profile ──────────────────────────────────────────────────────────────
export const options = {
  scenarios: {
    browsing: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '1m',  target: 500 },
        { duration: '1m',  target: 1000 },
        { duration: '1m',  target: 1000 },
        { duration: '1m', target: 50  },
      ],
      exec: 'browseFlow',
    },
    checkout: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '1m',  target: 200 },
        { duration: '1m',  target: 250 },
        { duration: '1m',  target: 250 },
        { duration: '1m', target: 10 },
      ],
      exec: 'checkoutFlow',
    },
  },
  thresholds: {
    http_req_failed:   ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
  },
};

// ── Scenario 1: Browse ────────────────────────────────────────────────────────
// Hits: frontend, productcatalog, recommendation, adservice heavily
// Hits: currencyservice (40%), cartservice (30%)
// No hits: payment, email, shipping, checkout
export function browseFlow() {
  get('/', 'home');
  sleep(rand(1, 2));

  // View 1–3 products
  for (let i = 0; i < rand(1, 3); i++) {
    get(`/product/${pick(PRODUCTS)}`, 'product');
    sleep(rand(1, 2));
  }

  // 40%: change currency
  if (Math.random() < 0.4) {
    post('/setCurrency', `currency_code=${pick(CURRENCIES)}`, 'currency');
    sleep(1);
  }

  // 30%: view cart
  if (Math.random() < 0.3) {
    get('/cart', 'cart');
    sleep(1);
  }

  sleep(rand(1, 3));
}

// ── Scenario 2: Checkout ──────────────────────────────────────────────────────
// Hits: frontend, productcatalog, cartservice, redis always
// Hits: checkoutservice, paymentservice, shippingservice, emailservice at 50%
export function checkoutFlow() {
  const product = pick(PRODUCTS);

  get(`/product/${product}`, 'product');
  sleep(rand(1, 2));

  post('/cart', `product_id=${product}&quantity=${rand(1, 3)}`, 'add_to_cart');
  sleep(1);

  get('/cart', 'cart');
  sleep(rand(1, 2));

  // 50%: complete the purchase
  if (Math.random() < 0.5) {
    post(
      '/cart/checkout',
      [
        'email=loadtest%40example.com',
        'street_address=123+Test+St',
        'zip_code=10001',
        'city=New+York',
        'state=NY',
        'country=US',
        'credit_card_number=4432801561520454',
        'credit_card_expiration_month=1',
        'credit_card_expiration_year=2030',
        'credit_card_cvv=672',
      ].join('&'),
      'checkout',
    );
    sleep(rand(2, 4));
  }

  sleep(rand(2, 4));
}
