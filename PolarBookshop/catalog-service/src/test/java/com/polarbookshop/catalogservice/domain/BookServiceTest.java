package com.polarbookshop.catalogservice.domain;

import java.time.Instant;
import java.util.Optional;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class BookServiceTest {

	@Mock
	private BookRepository bookRepository;

	@InjectMocks
	private BookService bookService;

	@Test
	void whenBookToCreateAlreadyExistsThenThrows() {
		var bookIsbn = "1234561232";
		var bookToCreate = Book.of(bookIsbn, "Title", "Author", 9.90, "Polarsophia");
		when(bookRepository.existsByIsbn(bookIsbn)).thenReturn(true);
		assertThatThrownBy(() -> bookService.addBookToCatalog(bookToCreate))
				.isInstanceOf(BookAlreadyExistsException.class)
				.hasMessage("A book with ISBN " + bookIsbn + " already exists.");
	}

	@Test
	void whenBookToReadDoesNotExistThenThrows() {
		var bookIsbn = "1234561232";
		when(bookRepository.findByIsbn(bookIsbn)).thenReturn(Optional.empty());
		assertThatThrownBy(() -> bookService.viewBookDetails(bookIsbn))
				.isInstanceOf(BookNotFoundException.class)
				.hasMessage("The book with ISBN " + bookIsbn + " was not found.");
	}

	@Test
	void whenBookToEditExistsThenUpdatesDetailsKeepingIdentity() {
		var bookIsbn = "1234561233";
		var now = Instant.now();
		var existingBook = new Book(42L, bookIsbn, "Title", "Author", 9.90, "Polarsophia",
				now, now, "isabelle", "isabelle", 3);
		var changes = Book.of(bookIsbn, "New Title", "New Author", 12.90, "New Publisher");
		when(bookRepository.findByIsbn(bookIsbn)).thenReturn(Optional.of(existingBook));
		when(bookRepository.save(any(Book.class))).thenAnswer(invocation -> invocation.getArgument(0));

		var updatedBook = bookService.editBookDetails(bookIsbn, changes);

		assertThat(updatedBook).isEqualTo(new Book(42L, bookIsbn, "New Title", "New Author", 12.90,
				"New Publisher", now, now, "isabelle", "isabelle", 3));
	}

	@Test
	void whenBookToEditDoesNotExistThenCreatesIt() {
		var bookIsbn = "1234561234";
		var bookToCreate = Book.of(bookIsbn, "Title", "Author", 9.90, "Polarsophia");
		when(bookRepository.findByIsbn(bookIsbn)).thenReturn(Optional.empty());
		when(bookRepository.existsByIsbn(bookIsbn)).thenReturn(false);
		when(bookRepository.save(bookToCreate)).thenReturn(bookToCreate);

		var createdBook = bookService.editBookDetails(bookIsbn, bookToCreate);

		assertThat(createdBook).isEqualTo(bookToCreate);
		verify(bookRepository).save(bookToCreate);
	}

}
