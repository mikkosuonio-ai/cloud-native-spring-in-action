package com.polarbookshop.edgeservice.config;

import org.junit.jupiter.api.Test;
import reactor.core.publisher.Mono;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.reactive.WebFluxTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ReactiveClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.reactive.server.WebTestClient;
import org.springframework.web.reactive.function.BodyInserters;

import static org.mockito.Mockito.when;

@WebFluxTest
@Import(SecurityConfig.class)
class SecurityConfigTests {

	@Autowired
	WebTestClient webClient;

	private static final String RAW_TOKEN = "3f2a6c1e-9b7d-4c5e-8a1f-0d2e4b6c8a90";

	@MockitoBean
	ReactiveClientRegistrationRepository clientRegistrationRepository;

	// polar-ui's fonts and other media files load before anyone logs in. No handler serves them
	// here, so a permitted request ends in 404, a denied one in 401.
	@Test
	void whenMediaFileNotAuthenticatedThenPermitted() {
		webClient
				.get()
				.uri("/media/roboto-latin-400-normal.woff2")
				.exchange()
				.expectStatus().isNotFound();
	}

	@Test
	void whenLogoutNotAuthenticatedAndNoCsrfTokenThen403() {
		webClient
				.post()
				.uri("/logout")
				.exchange()
				.expectStatus().isForbidden();
	}

	@Test
	void whenLogoutAuthenticatedAndNoCsrfTokenThen403() {
		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.post()
				.uri("/logout")
				.exchange()
				.expectStatus().isForbidden();
	}

	@Test
	void whenLogoutAuthenticatedAndWithCsrfTokenThen302() {
		when(clientRegistrationRepository.findByRegistrationId("test"))
				.thenReturn(Mono.just(testClientRegistration()));

		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.mutateWith(SecurityMockServerConfigurers.csrf())
				.post()
				.uri("/logout")
				.exchange()
				.expectStatus().isFound();
	}

	// polar-ui sends the XSRF-TOKEN cookie's value as it is, unmasked: Angular's interceptor in the
	// X-XSRF-TOKEN header of its writes, and the logout form in its _csrf field. Without a handler
	// for the books, a write that passes the CSRF check ends in 404.
	@Test
	void whenWriteWithRawCookieValueInHeaderThenCsrfPasses() {
		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.post()
				.uri("/books")
				.cookie("XSRF-TOKEN", RAW_TOKEN)
				.header("X-XSRF-TOKEN", RAW_TOKEN)
				.exchange()
				.expectStatus().isNotFound();
	}

	@Test
	void whenWriteWithOtherValueInHeaderThen403() {
		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.post()
				.uri("/books")
				.cookie("XSRF-TOKEN", RAW_TOKEN)
				.header("X-XSRF-TOKEN", "f00ba7")
				.exchange()
				.expectStatus().isForbidden();
	}

	@Test
	void whenLogoutFormWithRawCookieValueThen302() {
		when(clientRegistrationRepository.findByRegistrationId("test"))
				.thenReturn(Mono.just(testClientRegistration()));

		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.post()
				.uri("/logout")
				.cookie("XSRF-TOKEN", RAW_TOKEN)
				.contentType(MediaType.APPLICATION_FORM_URLENCODED)
				.body(BodyInserters.fromFormData("_csrf", RAW_TOKEN))
				.exchange()
				.expectStatus().isFound();
	}

	@Test
	void whenLogoutFormWithOtherValueThen403() {
		webClient
				.mutateWith(SecurityMockServerConfigurers.mockOidcLogin())
				.post()
				.uri("/logout")
				.cookie("XSRF-TOKEN", RAW_TOKEN)
				.contentType(MediaType.APPLICATION_FORM_URLENCODED)
				.body(BodyInserters.fromFormData("_csrf", "f00ba7"))
				.exchange()
				.expectStatus().isForbidden();
	}

	private ClientRegistration testClientRegistration() {
		return ClientRegistration.withRegistrationId("test")
				.authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
				.clientId("test")
				.authorizationUri("https://sso.polarbookshop.com/auth")
				.tokenUri("https://sso.polarbookshop.com/token")
				.redirectUri("https://polarbookshop.com")
				.build();
	}

}
