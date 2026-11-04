import { test, expect, SEEDED, bookCard, logIn, openMenu, orderCard } from './polar';

test('a customer orders a book and finds it in "My Orders"', async ({ page }) => {
  await logIn(page, 'bjorn');

  const menu = await openMenu(page);
  await expect(menu.addBook).toHaveCount(0);
  await menu.browseBooks.click();

  await bookCard(page, SEEDED.isbn).getByRole('button', { name: 'ORDER' }).click();
  const dialog = page.getByRole('dialog', { name: `Order ${SEEDED.title}` });
  await expect(dialog).toContainText(`By ${SEEDED.author}`);
  await dialog.getByRole('spinbutton', { name: 'Quantity' }).fill('2');
  // The order comes from the route, not from the page's response: Chromium sometimes no longer
  // has the body of a fetch response once the SPA has read it (review finding 53).
  let order: { id: number; status: string } | undefined;
  await page.route(/\/orders$/, async route => {
    if (route.request().method() !== 'POST') return route.fallback();
    const response = await route.fetch();
    expect(response.status()).toBe(200);
    order = await response.json();
    await route.fulfill({ response });
  });
  await dialog.getByRole('button', { name: 'Submit Order' }).click();
  await expect.poll(() => order?.status).toBe('ACCEPTED');

  await expect(page).toHaveURL(/#\/my-orders$/);
  await expect(page.getByRole('heading', { name: 'My Orders' })).toBeVisible();
  const card = orderCard(page, order!.id);
  await expect(card).toContainText(`Book: ${SEEDED.title}`);
  await expect(card).toContainText(`ISBN: ${SEEDED.isbn}`);
  await expect(card).toContainText('Quantity: 2');
  // dispatcher-service, when it runs, dispatches the order within moments.
  await expect(card).toContainText(/Status: (ACCEPTED|DISPATCHED)/);
  await expect(card).toContainText('Total: $19.80');
});
