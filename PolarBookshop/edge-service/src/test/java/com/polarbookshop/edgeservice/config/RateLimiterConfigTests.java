package com.polarbookshop.edgeservice.config;

import org.junit.jupiter.api.Test;
import reactor.core.publisher.Mono;
import reactor.test.StepVerifier;

import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.TestingAuthenticationToken;

class RateLimiterConfigTests {

	private final KeyResolver keyResolver = new RateLimiterConfig().keyResolver();

	@Test
	void whenAuthenticatedThenKeyIsUsername() {
		var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/orders"))
				.mutate()
				.principal(Mono.just(new TestingAuthenticationToken("bjorn", null)))
				.build();

		StepVerifier.create(keyResolver.resolve(exchange))
				.expectNext("bjorn")
				.verifyComplete();
	}

	@Test
	void whenNotAuthenticatedThenKeyIsAnonymous() {
		var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/books"));

		StepVerifier.create(keyResolver.resolve(exchange))
				.expectNext("anonymous")
				.verifyComplete();
	}

}
