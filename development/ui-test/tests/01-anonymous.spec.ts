import { test, expect, SEEDED, bookCard, openMenu } from './polar';

test('an anonymous visitor sees "Log In" and only "Browse Books" in the menu', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('Polar Bookshop', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Log In' })).toBeVisible();
  const menu = await openMenu(page);
  await expect(menu.addBook).toHaveCount(0);
  await expect(menu.myOrders).toHaveCount(0);
});

test('an anonymous visitor browses the catalog', async ({ page }) => {
  await page.goto('/');
  const menu = await openMenu(page);
  await menu.browseBooks.click();
  await expect(page).toHaveURL(/#\/browse-books$/);
  await expect(page.getByRole('heading', { name: 'Browse Books' })).toBeVisible();
  const card = bookCard(page, SEEDED.isbn);
  await expect(card).toContainText(SEEDED.title);
  await expect(card).toContainText(`Author: ${SEEDED.author}`);
  await expect(card).toContainText(`Price: $${SEEDED.price}`);
  await expect(card.getByRole('button', { name: 'ORDER' })).toBeVisible();
  expect(await page.locator('mat-card.dashboard-card').count()).toBeGreaterThanOrEqual(2);
});
