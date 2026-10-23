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
  const submitted = page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/orders'));
  await dialog.getByRole('button', { name: 'Submit Order' }).click();
  const response = await submitted;
  expect(response.status()).toBe(200);
  const order = await response.json();
  expect(order.status).toBe('ACCEPTED');

  await expect(page).toHaveURL(/#\/my-orders$/);
  await expect(page.getByRole('heading', { name: 'My Orders' })).toBeVisible();
  const card = orderCard(page, order.id);
  await expect(card).toContainText(`Book: ${SEEDED.title}`);
  await expect(card).toContainText(`ISBN: ${SEEDED.isbn}`);
  await expect(card).toContainText('Quantity: 2');
  // dispatcher-service, when it runs, dispatches the order within moments.
  await expect(card).toContainText(/Status: (ACCEPTED|DISPATCHED)/);
  await expect(card).toContainText('Total: $19.80');
});
