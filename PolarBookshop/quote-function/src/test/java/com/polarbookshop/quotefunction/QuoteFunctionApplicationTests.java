package com.polarbookshop.quotefunction;

import java.time.Duration;

import com.polarbookshop.quotefunction.domain.Genre;
import com.polarbookshop.quotefunction.domain.Quote;
import org.awaitility.Awaitility;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.webtestclient.autoconfigure.AutoConfigureWebTestClient;
import org.springframework.http.MediaType;
import org.springframework.test.web.reactive.server.WebTestClient;

import static org.assertj.core.api.Assertions.assertThat;

@AutoConfigureWebTestClient
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ExtendWith(OutputCaptureExtension.class)
class QuoteFunctionApplicationTests {

	@Autowired
	WebTestClient webTestClient;

	@Test
	void whenAllQuotesThenReturn() {
		webTestClient
				.get()
				.uri("/")
				.exchange()
				.expectStatus().is2xxSuccessful()
				.expectBodyList(Quote.class);
	}

	@Test
	void whenRandomQuoteThenReturn() {
		webTestClient
				.get()
				.uri("/randomQuote")
				.exchange()
				.expectStatus().is2xxSuccessful()
				.expectBody(Quote.class);
	}

	@Test
	void whenGenreQuoteThenReturn() {
		webTestClient
				.post()
				.uri("/genreQuote")
				.bodyValue("FANTASY")
				.exchange()
				.expectStatus().is2xxSuccessful()
				.expectBody(Quote.class)
				.value(quote -> assertThat(quote.genre()).isEqualTo(Genre.FANTASY));
	}

	@Test
	void whenGenreQuoteWithUnknownGenreThenBadRequest() {
		webTestClient
				.post()
				.uri("/genreQuote")
				.bodyValue("POETRY")
				.exchange()
				.expectStatus().isBadRequest();
	}

	// As clients send it: JSON. Jackson rejects the unknown genre; it must stay a client error.
	@Test
	void whenGenreQuoteWithUnknownGenreAsJsonThenBadRequest() {
		webTestClient
				.post()
				.uri("/genreQuote")
				.contentType(MediaType.APPLICATION_JSON)
				.bodyValue("\"POETRY\"")
				.exchange()
				.expectStatus().isBadRequest();
	}

	@Test
	void whenGenreQuoteWithoutGenreThenBadRequest() {
		webTestClient
				.post()
				.uri("/genreQuote")
				.exchange()
				.expectStatus().isBadRequest();
	}

	@Test
	void whenGenreQuoteByGetWithoutGenreThenBadRequest() {
		webTestClient
				.get()
				.uri("/genreQuote")
				.exchange()
				.expectStatus().isBadRequest();
	}

	// The composition used to answer 202 while it failed: Spring Cloud Function 4.3 threw a
	// ClassCastException after a Mono output, and an invalid JSON body is dropped with only a log
	// entry. So the test sends JSON, as clients do, and checks that the quote is logged.
	@Test
	void whenGenreQuoteLogQuoteThenReturnAndLogged(CapturedOutput output) {
		webTestClient
				.post()
				.uri("/genreQuote,logQuote")
				.contentType(MediaType.APPLICATION_JSON)
				.bodyValue("\"FANTASY\"")
				.exchange()
				.expectStatus().isAccepted();
		Awaitility.await().atMost(Duration.ofSeconds(5))
				.untilAsserted(() -> assertThat(output.getOut()).containsPattern("Quote: '.*' by (Casper|Dobby)"));
	}

}
