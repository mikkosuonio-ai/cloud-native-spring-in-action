package com.polarbookshop.catalogservice;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * Error responses to anonymous requests keep their status instead of becoming 401. Runs against a
 * real server, since only it makes the error dispatch that renders them, and without PostgreSQL.
 */
@SpringBootTest(
		webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = {
				"spring.datasource.url=jdbc:postgresql://127.0.0.1:1/polardb_catalog",
				"spring.datasource.hikari.connection-timeout=250",
				"spring.data.jdbc.dialect=postgresql",
				"spring.flyway.enabled=false"
		})
// Any profile but testdata, which loads books at startup.
@ActiveProfiles("database-down")
class CatalogServiceErrorResponsesTests {

	@Autowired
	private WebTestClient webTestClient;

	@Test
	void whenGetPathWithoutHandlerThen404() {
		webTestClient
				.get()
				.uri("/books/")
				.exchange()
				.expectStatus().isNotFound();
	}

	@Test
	void whenDatabaseDownThen500() {
		webTestClient
				.get()
				.uri("/books")
				.exchange()
				.expectStatus().isEqualTo(500);
	}

}
