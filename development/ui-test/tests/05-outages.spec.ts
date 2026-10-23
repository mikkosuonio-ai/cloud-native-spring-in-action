import { test, expect, failedCall, logIn, uniqueIsbn, withCatalogDatabaseClosed, withPaused } from './polar';

// These tests break parts of the stack, so they come last, and each waits until edge-service
// serves the catalog again before it ends.
test.describe.configure({ mode: 'serial' });

test.afterEach(async ({ request }) => {
  await expect.poll(async () => {
    const response = await request.get('/books');
    return response.status() === 200 && (await response.text()).includes('"isbn"');
  }, { timeout: 30_000 }).toBe(true);
});

// Review finding 1: catalog-service used to answer server errors with 401, and the SPA then
// sent a logged-in employee to Keycloak's login page. GETs don't show it through edge-service,
// whose Retry filter repeats them until the circuit breaker's time limit gives the fallback;
// writes aren't retried.
test('a catalog-service server error leaves an employee logged in', async ({ page, problems }) => {
  problems.allow(...failedCall('POST', '/books', 500));
  await logIn(page, 'isabelle');
  await page.goto('/#/add-book');
  await page.getByRole('textbox', { name: 'ISBN' }).fill(uniqueIsbn());
  await page.getByRole('textbox', { name: 'Title' }).fill('Never Stored');
  await page.getByRole('textbox', { name: 'Author' }).fill('Browser Tester');
  await page.getByRole('spinbutton', { name: 'Price' }).fill('1');

  await withCatalogDatabaseClosed(async () => {
    const created = page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/books'));
    await page.getByRole('button', { name: 'Create Book' }).click();
    expect((await created).status()).toBe(500);
    // Give a redirect to the login page, which the interceptor would start at once, time to begin.
    await page.waitForTimeout(1000);
    await expect(page).toHaveURL(/#\/add-book$/);
    await expect(page.getByRole('button', { name: 'Log Out' })).toBeVisible();
  });
});

// With catalog-service frozen, edge-service's circuit breaker answers GET /books with its
// fallback after the 5 s time limit.
test('the catalog fallback answers without books while catalog-service is frozen', async ({ request }) => {
  await withPaused('catalog-service', async () => {
    const response = await request.get('/books', { timeout: 15_000 });
    expect(response.status()).toBe(200);
    expect(await response.text()).not.toContain('"isbn"');
  });
});

// The fallback is an empty string, not a JSON list (review finding 32). HttpClient parses it as
// null, so the book list shows a spinner for good instead of an empty list. Until the response
// comes, the list is empty, so the test waits for it. When this test passes, finding 32 is
// fixed: remove the test.fail.
test('the catalog fallback shows an empty book list', async ({ page }) => {
  test.fail(true, 'review finding 32: the fallback body is "", so the list shows a spinner for good');
  await withPaused('catalog-service', async () => {
    const books = page.waitForResponse(r => r.request().method() === 'GET' && r.url().endsWith('/books'),
      { timeout: 15_000 });
    await page.goto('/#/browse-books');
    expect((await books).status()).toBe(200);
    await expect(page.locator('mat-spinner')).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Browse Books' })).toBeVisible();
    await expect(page.locator('mat-card.dashboard-card')).toHaveCount(0);
  });
});
