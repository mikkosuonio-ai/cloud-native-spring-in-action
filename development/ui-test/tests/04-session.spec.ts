import { test, expect, KEYCLOAK, failedCall, logIn } from './polar';

// The logout form posts the XSRF-TOKEN cookie's value as _csrf. edge-service ends the session
// and sends the browser through Keycloak's logout, which returns it to edge-service.
test('logging out ends the session in edge-service and Keycloak', async ({ page }) => {
  await logIn(page, 'isabelle');
  const visited: string[] = [];
  page.on('request', r => { if (r.isNavigationRequest()) visited.push(r.url()); });
  await page.getByRole('button', { name: 'Log Out' }).click();
  await expect(page.getByRole('button', { name: 'Log In' })).toBeVisible();
  expect(visited.some(u => u.startsWith(`${KEYCLOAK}/realms/PolarBookshop/protocol/openid-connect/logout`)),
    `went through Keycloak's logout: ${visited.join(', ')}`).toBe(true);

  // Logging in again needs the credentials: Keycloak's session is gone too.
  await page.getByRole('button', { name: 'Log In' }).click();
  await page.waitForURL(`${KEYCLOAK}/realms/PolarBookshop/**`);
  await expect(page.locator('#kc-form-login')).toBeVisible();
});

// HttpInterceptorImpl sends the browser to log in on a 401 from anything but GET /user. Review
// finding 1 made catalog-service answer server errors with 5xx instead of 401, which made the
// SPA ask a logged-in user to log in again; see 05-outages for that side.
test('a 401 from an API sends an anonymous visitor to log in', async ({ page, problems }) => {
  problems.allow(...failedCall('GET', '/orders', 401));
  await page.goto('/#/my-orders');
  await page.waitForURL(`${KEYCLOAK}/realms/PolarBookshop/protocol/openid-connect/auth**`);
  await expect(page.locator('#kc-form-login')).toBeVisible();
});
