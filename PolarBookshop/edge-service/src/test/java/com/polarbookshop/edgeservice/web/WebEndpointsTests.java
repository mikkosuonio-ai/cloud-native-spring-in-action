package com.polarbookshop.edgeservice.web;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.http.HttpStatus;
import org.springframework.test.web.reactive.server.WebTestClient;

class WebEndpointsTests {

	private WebTestClient webClient;

	@BeforeEach
	void setUp() {
		webClient = WebTestClient.bindToRouterFunction(new WebEndpoints().routerFunction()).build();
	}

	@Test
	void whenGetCatalogFallbackThenEmptyResponse() {
		webClient
				.get()
				.uri("/catalog-fallback")
				.exchange()
				.expectStatus().isOk()
				.expectBody().isEmpty();
	}

	@Test
	void whenPostCatalogFallbackThen503() {
		webClient
				.post()
				.uri("/catalog-fallback")
				.exchange()
				.expectStatus().isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
	}

}
