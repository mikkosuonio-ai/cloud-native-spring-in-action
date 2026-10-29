import { test as base, expect, type ConsoleMessage, type Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';

export { expect };

export const KEYCLOAK = 'http://host.docker.internal:8080';

// One of the books catalog-service's testdata profile loads at startup.
export const SEEDED = { isbn: '1234567891', title: 'Northern Lights', author: 'Lyra Silverstar', price: 9.9 };

// What a page does on every anonymous load: GET /user answers 401, and AppComponent, which
// subscribes to it without an error handler, logs the error.
const ANONYMOUS_USER = [
  /^HTTP 401 GET .*\/user$/,
  /^console: Failed to load resource: the server responded with a status of 401 .*\[.*\/user\]$/,
  /^Angular ERROR 401 .*\/user$/,
];

// Patterns for the problems a test expects of an HTTP call: its response with STATUS, the
// browser's console line for it, and the error Angular logs when nothing handles it.
export function failedCall(method: string, path: string, status: number): RegExp[] {
  const url = path.replace(/[/.?]/g, '\\$&');
  return [
    new RegExp(`^HTTP ${status} ${method} .*${url}$`),
    new RegExp(`^console: Failed to load resource: the server responded with a status of ${status} .*\\[.*${url}\\]$`),
    new RegExp(`^Angular ERROR ${status} .*${url}$`),
  ];
}

type Problems = { allow(...patterns: RegExp[]): void };

// Every book the tests create has an ISBN with this prefix; the curl smoke tests use 98 and 99.
const OWN_ISBNS = '97';

// Google Fonts: polar-ui serves its fonts and icons itself under /media/ (since v2.0.0). The
// tests block Google's font hosts without allowing it, so a request to them fails the test.
const FONTS = /^https:\/\/fonts\.(googleapis|gstatic)\.com\//;

// Every test fails on a browser problem it doesn't expect: a response of 400 or more, a failed
// request, an uncaught page error, or a console error.
export const test = base.extend<{ problems: Problems; ownBooks: void }>({
  problems: [async ({ page }, use) => {
    const seen: string[] = [];
    const allowed = [...ANONYMOUS_USER];

    await page.route(FONTS, route => route.abort('blockedbyclient'));
    // Angular's ErrorHandler logs console.error('ERROR', error). Name an HttpErrorResponse by its
    // status and URL, in the page itself: after a redirect, the error object can't be read.
    await page.addInitScript(() => {
      const error = console.error.bind(console);
      console.error = (...args: any[]) => error(...args.map(a =>
        a?.name === 'HttpErrorResponse' ? `HttpErrorResponse ${a.status} ${a.url}` : a));
    });

    page.on('response', r => {
      if (r.status() >= 400) seen.push(`HTTP ${r.status()} ${r.request().method()} ${r.url()}`);
    });
    page.on('requestfailed', r => {
      // Navigating away cancels the requests still running; that's no problem of the page.
      if (r.failure()?.errorText !== 'net::ERR_ABORTED') {
        seen.push(`request failed ${r.method()} ${r.url()}: ${r.failure()?.errorText}`);
      }
    });
    page.on('pageerror', e => seen.push(`page error: ${e.message}`));
    page.on('console', (m: ConsoleMessage) => {
      if (m.type() !== 'error') return;
      const angular = /^ERROR HttpErrorResponse (\d+) (\S+)$/.exec(m.text());
      seen.push(angular ? `Angular ERROR ${angular[1]} ${angular[2]}` : `console: ${m.text()} [${m.location().url}]`);
    });

    await use({ allow: (...patterns) => allowed.push(...patterns) });

    const unexpected = seen.filter(p => !allowed.some(a => a.test(p)));
    expect(unexpected, 'browser problems the test does not expect').toEqual([]);
  }, { auto: true }],

  // Every test starts and ends without the tests' books, also when it fails before removing its
  // own, or an earlier run was killed. The tests run one at a time, so no other test's books go.
  ownBooks: [async ({}, use) => {
    removeOwnBooks();
    await use();
    removeOwnBooks();
  }, { auto: true }],
});

// A 10-digit ISBN that no other book in the catalog has.
export function uniqueIsbn(): string {
  return OWN_ISBNS + String(Date.now()).slice(-8);
}

// The podman arguments that run STATEMENT in polar-postgres, on DATABASE, as its superuser.
function psql(database: string, statement: string): string[] {
  return ['exec', 'polar-postgres', 'psql', '-U', 'user', '-d', database, '-v', 'ON_ERROR_STOP=1', '-c', statement];
}

// Deletes the tests' books from catalog-service's database directly: a test may have logged
// out, or broken catalog-service, by the time it ends.
function removeOwnBooks() {
  execFileSync('podman', psql('polardb_catalog', `DELETE FROM book WHERE isbn LIKE '${OWN_ISBNS}%'`), { stdio: 'pipe' });
}

// Logs USERNAME in as a user would: "Log In", Keycloak's form, and back to the SPA.
export async function logIn(page: Page, username: string): Promise<void> {
  await page.goto('/');
  await page.getByRole('button', { name: 'Log In' }).click();
  await page.waitForURL(`${KEYCLOAK}/realms/PolarBookshop/**`);
  await page.locator('#username').fill(username);
  await page.locator('#password').fill('password');
  await page.locator('#kc-login').click();
  await page.waitForURL(url => !url.href.startsWith(KEYCLOAK));
  await expect(page.getByRole('button', { name: 'Log Out' })).toBeVisible();
}

// Opens the side menu and returns its links; links a user mustn't see aren't rendered at all.
export async function openMenu(page: Page) {
  await page.getByRole('button', { name: 'Toggle sidenav' }).click();
  const menu = page.getByRole('navigation').getByRole('navigation');
  await expect(menu.getByRole('link', { name: 'Browse Books', exact: true })).toBeVisible();
  return {
    browseBooks: menu.getByRole('link', { name: 'Browse Books', exact: true }),
    addBook: menu.getByRole('link', { name: 'Add Book', exact: true }),
    myOrders: menu.getByRole('link', { name: 'My Orders', exact: true }),
  };
}

// The card of the book with ISBN on the "Browse Books" page.
export function bookCard(page: Page, isbn: string) {
  return page.locator('mat-card.dashboard-card').filter({ hasText: `ISBN: ${isbn}` });
}

// The card of the order with ID on the "My Orders" page.
export function orderCard(page: Page, id: number) {
  return page.locator('mat-card.dashboard-card').filter({
    has: page.locator('mat-card-title', { hasText: new RegExp(`^\\s*Order #${id}\\s*$`) }),
  });
}

// Adds BOOK to the catalog through edge-service, in the session of PAGE's logged-in user.
export async function addBook(page: Page, book: { isbn: string; title: string; author: string; price: number }) {
  const xsrf = (await page.context().cookies()).find(c => c.name === 'XSRF-TOKEN')?.value ?? '';
  const response = await page.request.post('/books', { data: book, headers: { 'X-XSRF-TOKEN': xsrf } });
  expect(response.status(), await response.text()).toBe(201);
}

// Runs `podman DO...`, then FN, and `podman UNDO...` even when FN fails. Notes UNDO in
// UI_UNDO_FILE meanwhile, one argument list per line, separated by tabs, so that the smoke
// script can run it if the test run itself is killed.
async function withPodman(doArgs: string[], undoArgs: string[], fn: () => Promise<void>) {
  const note = process.env.UI_UNDO_FILE;
  const line = undoArgs.join('\t');
  if (note) appendFileSync(note, line + '\n');
  try {
    execFileSync('podman', doArgs, { stdio: 'pipe' });
    await fn();
  } finally {
    execFileSync('podman', undoArgs, { stdio: 'pipe' });
    if (note) {
      const rest = readFileSync(note, 'utf8').split('\n').filter(l => l && l !== line);
      writeFileSync(note, rest.map(l => l + '\n').join(''));
    }
  }
}

// Pauses CONTAINER of the stack for the length of FN.
export function withPaused(container: string, fn: () => Promise<void>) {
  return withPodman(['pause', container], ['unpause', container], fn);
}

// Closes catalog-service's database for the length of FN: PostgreSQL refuses new connections to
// it, also from superusers, and ends the open ones, so that catalog-service fails with 500
// after its 2 s connection timeout. Stopping polar-postgres would do that too, but order-service
// then answers the first orders after the restart with 500 (review finding 36).
export function withCatalogDatabaseClosed(fn: () => Promise<void>) {
  return withPodman(
    psql('postgres', "ALTER DATABASE polardb_catalog ALLOW_CONNECTIONS false; "
      + "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'polardb_catalog'"),
    psql('postgres', 'ALTER DATABASE polardb_catalog ALLOW_CONNECTIONS true'),
    fn);
}
