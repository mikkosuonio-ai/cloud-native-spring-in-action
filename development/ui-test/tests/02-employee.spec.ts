import { test, expect, SEEDED, addBook, bookCard, logIn, openMenu, uniqueIsbn } from './polar';

// Each write goes through Angular's HttpClient, which sends the XSRF-TOKEN cookie back as the
// X-XSRF-TOKEN header itself, and edge-service relays isabelle's token to catalog-service.
test('an employee adds, edits and removes a book', async ({ page }) => {
  const isbn = uniqueIsbn();
  await logIn(page, 'isabelle');

  await test.step('the menu has "Add Book" and "My Orders"', async () => {
    const menu = await openMenu(page);
    await expect(menu.myOrders).toBeVisible();
    await menu.addBook.click();
    await expect(page).toHaveURL(/#\/add-book$/);
  });

  await test.step('add a book', async () => {
    await page.getByRole('textbox', { name: 'ISBN' }).fill(isbn);
    await page.getByRole('textbox', { name: 'Title' }).fill('UI Smoke Test');
    await page.getByRole('textbox', { name: 'Author' }).fill('Browser Tester');
    await page.getByRole('textbox', { name: 'Publisher' }).fill('Polarsophia');
    await page.getByRole('spinbutton', { name: 'Price' }).fill('7.5');
    const created = page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/books'));
    await page.getByRole('button', { name: 'Create Book' }).click();
    expect((await created).status()).toBe(201);
    await expect(page).toHaveURL(/#\/browse-books$/);
    const card = bookCard(page, isbn);
    await expect(card).toContainText('UI Smoke Test');
    await expect(card).toContainText('Price: $7.5');
  });

  await test.step('edit its price', async () => {
    await bookCard(page, isbn).getByRole('button', { name: 'Toggle menu' }).click();
    await page.getByRole('menuitem', { name: 'Edit' }).click();
    await expect(page).toHaveURL(new RegExp(`#/edit-book/${isbn}$`));
    const price = page.getByRole('spinbutton', { name: 'Price' });
    await expect(price).toHaveValue('7.5');
    await price.fill('8.25');
    const updated = page.waitForResponse(r => r.request().method() === 'PUT' && r.url().endsWith(`/books/${isbn}`));
    await page.getByRole('button', { name: 'Update Book' }).click();
    expect((await updated).status()).toBe(200);
    await expect(page).toHaveURL(/#\/browse-books$/);
    await expect(bookCard(page, isbn)).toContainText('Price: $8.25');
  });

  await test.step('remove it', async () => {
    await bookCard(page, isbn).getByRole('button', { name: 'Toggle menu' }).click();
    const removed = page.waitForResponse(r => r.request().method() === 'DELETE' && r.url().endsWith(`/books/${isbn}`));
    await page.getByRole('menuitem', { name: 'Remove' }).click();
    expect((await removed).status()).toBe(204);
    // The list itself still shows the book; see the next test.
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Browse Books' })).toBeVisible();
    await expect(bookCard(page, SEEDED.isbn)).toBeVisible();
    await expect(bookCard(page, isbn)).toHaveCount(0);
  });
});

// BookListComponent.removeBook navigates to /browse-books, the page it's on, and Angular's
// router ignores a navigation to the current URL, so the list isn't loaded again (review
// finding 37). When this test passes, the finding is fixed: remove the test.fail.
test('removing a book takes it off the list', async ({ page }) => {
  test.fail(true, 'review finding 37: the list keeps a removed book until the page is loaded again');
  const isbn = uniqueIsbn();
  await logIn(page, 'isabelle');
  await addBook(page, { isbn, title: 'UI Smoke Test', author: 'Browser Tester', price: 7.5 });
  await page.goto('/#/browse-books');
  await bookCard(page, isbn).getByRole('button', { name: 'Toggle menu' }).click();
  const removed = page.waitForResponse(r => r.request().method() === 'DELETE' && r.url().endsWith(`/books/${isbn}`));
  await page.getByRole('menuitem', { name: 'Remove' }).click();
  expect((await removed).status()).toBe(204);
  await expect(bookCard(page, isbn)).toHaveCount(0);
});
