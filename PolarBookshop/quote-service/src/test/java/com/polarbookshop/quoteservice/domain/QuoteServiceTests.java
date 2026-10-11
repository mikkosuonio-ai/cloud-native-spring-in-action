package com.polarbookshop.quoteservice.domain;

import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class QuoteServiceTests {

	private final QuoteService quoteService = new QuoteService();

	@Test
	void randomQuoteCanReturnEveryQuote() {
		Set<String> authors = IntStream.range(0, 200)
				.mapToObj(i -> quoteService.getRandomQuote().block().author())
				.collect(Collectors.toSet());
		assertThat(authors).containsExactlyInAnyOrder("Abigail", "Beatrix", "Casper", "Dobby", "Eileen", "Flora");
	}

	@Test
	void randomQuoteByGenreCanReturnEveryQuoteOfTheGenre() {
		Set<String> authors = IntStream.range(0, 100)
				.mapToObj(i -> quoteService.getRandomQuoteByGenre(Genre.FANTASY).block().author())
				.collect(Collectors.toSet());
		assertThat(authors).containsExactlyInAnyOrder("Casper", "Dobby");
	}

}
