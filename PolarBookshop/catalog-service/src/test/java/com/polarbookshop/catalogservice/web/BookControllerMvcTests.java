package com.polarbookshop.catalogservice.web;

import java.util.List;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.polarbookshop.catalogservice.config.SecurityConfig;
import com.polarbookshop.catalogservice.domain.Book;
import com.polarbookshop.catalogservice.domain.BookAlreadyExistsException;
import com.polarbookshop.catalogservice.domain.BookNotFoundException;
import com.polarbookshop.catalogservice.domain.BookService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(BookController.class)
@Import(SecurityConfig.class)
class BookControllerMvcTests {

	private static final String ROLE_EMPLOYEE = "ROLE_employee";
	private static final String ROLE_CUSTOMER = "ROLE_customer";

	@Autowired
	MockMvc mockMvc;

	@Autowired
	ObjectMapper objectMapper;

	@MockitoBean
	BookService bookService;

	@Test
	void whenGetBooksNotAuthenticatedThenShouldReturnAllBooks() throws Exception {
		var book1 = Book.of("7373731394", "Title", "Author", 9.90, "Polarsophia");
		var book2 = Book.of("7373731395", "Another Title", "Author", 12.90, "Polarsophia");
		given(bookService.viewBookList()).willReturn(List.of(book1, book2));
		mockMvc
				.perform(get("/books"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.length()").value(2))
				.andExpect(jsonPath("$[0].isbn").value(book1.isbn()))
				.andExpect(jsonPath("$[1].isbn").value(book2.isbn()));
	}

	@Test
	void whenGetBookExistingAndAuthenticatedThenShouldReturn200() throws Exception {
		var isbn = "7373731394";
		var expectedBook = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		given(bookService.viewBookDetails(isbn)).willReturn(expectedBook);
		mockMvc
				.perform(get("/books/" + isbn)
						.with(jwt()))
				.andExpect(status().isOk());
	}

	@Test
	void whenGetBookExistingAndNotAuthenticatedThenShouldReturn200() throws Exception {
		var isbn = "7373731394";
		var expectedBook = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		given(bookService.viewBookDetails(isbn)).willReturn(expectedBook);
		mockMvc
				.perform(get("/books/" + isbn))
				.andExpect(status().isOk());
	}

	@Test
	void whenGetBookNotExistingAndAuthenticatedThenShouldReturn404() throws Exception {
		var isbn = "7373731394";
		given(bookService.viewBookDetails(isbn)).willThrow(BookNotFoundException.class);
		mockMvc
				.perform(get("/books/" + isbn)
						.with(jwt()))
				.andExpect(status().isNotFound());
	}

	@Test
	void whenGetBookNotExistingAndNotAuthenticatedThenShouldReturn404() throws Exception {
		var isbn = "7373731394";
		given(bookService.viewBookDetails(isbn)).willThrow(BookNotFoundException.class);
		mockMvc
				.perform(get("/books/" + isbn))
				.andExpect(status().isNotFound());
	}

	@Test
	void whenDeleteBookWithEmployeeRoleThenShouldReturn204() throws Exception {
		var isbn = "7373731394";
		mockMvc
				.perform(delete("/books/" + isbn)
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_EMPLOYEE))))
				.andExpect(status().isNoContent());
	}

	@Test
	void whenDeleteBookWithCustomerRoleThenShouldReturn403() throws Exception {
		var isbn = "7373731394";
		mockMvc
				.perform(delete("/books/" + isbn)
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_CUSTOMER))))
				.andExpect(status().isForbidden());
	}

	@Test
	void whenDeleteBookNotAuthenticatedThenShouldReturn401() throws Exception {
		var isbn = "7373731394";
		mockMvc
				.perform(delete("/books/" + isbn))
				.andExpect(status().isUnauthorized());
	}

	@Test
	void whenPostBookWithEmployeeRoleThenShouldReturn201() throws Exception {
		var isbn = "7373731394";
		var bookToCreate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		given(bookService.addBookToCatalog(bookToCreate)).willReturn(bookToCreate);
		mockMvc
				.perform(post("/books")
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToCreate))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_EMPLOYEE))))
				.andExpect(status().isCreated());
	}

	@Test
	void whenPostBookWithCustomerRoleThenShouldReturn403() throws Exception {
		var isbn = "7373731394";
		var bookToCreate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		mockMvc
				.perform(post("/books")
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToCreate))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_CUSTOMER))))
				.andExpect(status().isForbidden());
		verifyNoInteractions(bookService);
	}

	@Test
	void whenPostBookAndNotAuthenticatedThenShouldReturn401() throws Exception {
		var isbn = "7373731394";
		var bookToCreate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		mockMvc
				.perform(post("/books")
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToCreate)))
				.andExpect(status().isUnauthorized());
	}

	@Test
	void whenPutBookWithEmployeeRoleThenShouldReturn200() throws Exception {
		var isbn = "7373731394";
		var bookToUpdate = Book.of(isbn, "Title", "Author", 7.95, "Polarsophia");
		given(bookService.editBookDetails(isbn, bookToUpdate)).willReturn(bookToUpdate);
		mockMvc
				.perform(put("/books/" + isbn)
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToUpdate))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_EMPLOYEE))))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.isbn").value(isbn))
				.andExpect(jsonPath("$.price").value(7.95));
	}

	@Test
	void whenPutBookWithCustomerRoleThenShouldReturn403() throws Exception {
		var isbn = "7373731394";
		var bookToUpdate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		mockMvc
				.perform(put("/books/" + isbn)
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToUpdate))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_CUSTOMER))))
				.andExpect(status().isForbidden());
		verifyNoInteractions(bookService);
	}

	@Test
	void whenPutBookAndNotAuthenticatedThenShouldReturn401() throws Exception {
		var isbn = "7373731394";
		var bookToCreate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		mockMvc
				.perform(put("/books/" + isbn)
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToCreate)))
				.andExpect(status().isUnauthorized());
	}

	@Test
	void whenPostBookWithInvalidFieldsThenShouldReturn400WithErrors() throws Exception {
		var invalidBook = Book.of("a234567890", "", "Author", -9.90, "Polarsophia");
		mockMvc
				.perform(post("/books")
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(invalidBook))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_EMPLOYEE))))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.isbn").value("The ISBN format must be valid."))
				.andExpect(jsonPath("$.title").value("The book title must be defined."))
				.andExpect(jsonPath("$.price").value("The book price must be greater than zero."))
				.andExpect(jsonPath("$.author").doesNotExist());
	}

	@Test
	void whenPostBookAlreadyExistingThenShouldReturn422() throws Exception {
		var isbn = "7373731394";
		var bookToCreate = Book.of(isbn, "Title", "Author", 9.90, "Polarsophia");
		given(bookService.addBookToCatalog(bookToCreate)).willThrow(new BookAlreadyExistsException(isbn));
		mockMvc
				.perform(post("/books")
						.contentType(MediaType.APPLICATION_JSON)
						.content(objectMapper.writeValueAsString(bookToCreate))
						.with(jwt().authorities(new SimpleGrantedAuthority(ROLE_EMPLOYEE))))
				.andExpect(status().isUnprocessableEntity())
				.andExpect(content().string("A book with ISBN " + isbn + " already exists."));
	}

}
