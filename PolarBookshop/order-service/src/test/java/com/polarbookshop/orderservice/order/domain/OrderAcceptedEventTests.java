package com.polarbookshop.orderservice.order.domain;

import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.polarbookshop.orderservice.book.Book;
import com.polarbookshop.orderservice.book.BookClient;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import reactor.core.publisher.Mono;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.cloud.stream.binder.test.TestChannelBinderConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.integration.config.GlobalChannelInterceptor;
import org.springframework.messaging.Message;
import org.springframework.messaging.MessageChannel;
import org.springframework.messaging.support.ChannelInterceptor;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.BDDMockito.given;

/**
 * dispatcher-service can answer an order-accepted event within milliseconds, and order-service
 * then looks the order up from another connection. The order must be committed by the time the
 * event is sent, or the lookup finds nothing and the order-dispatched event is lost.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.NONE)
@Import({TestChannelBinderConfiguration.class, OrderAcceptedEventTests.VisibilityProbe.class})
@Testcontainers
class OrderAcceptedEventTests {

	@Container
	static PostgreSQLContainer<?> postgresql = new PostgreSQLContainer<>(DockerImageName.parse("postgres:14.12"));

	@Autowired
	private OrderService orderService;

	@Autowired
	private VisibilityProbe probe;

	@MockBean
	private BookClient bookClient;

	// SecurityConfig needs one; without a web server, no token is ever decoded.
	@MockBean
	private ReactiveJwtDecoder jwtDecoder;

	@DynamicPropertySource
	static void postgresqlProperties(DynamicPropertyRegistry registry) {
		registry.add("spring.r2dbc.url", () -> String.format("r2dbc:postgresql://%s:%s/%s", postgresql.getHost(),
				postgresql.getMappedPort(PostgreSQLContainer.POSTGRESQL_PORT), postgresql.getDatabaseName()));
		registry.add("spring.r2dbc.username", postgresql::getUsername);
		registry.add("spring.r2dbc.password", postgresql::getPassword);
		registry.add("spring.flyway.url", postgresql::getJdbcUrl);
	}

	@Test
	void whenOrderAcceptedEventSentThenOrderAlreadyCommitted() {
		var book = new Book("1234567890", "Title", "Author", 9.90);
		given(bookClient.getBookByIsbn(book.isbn())).willReturn(Mono.just(book));

		var order = orderService.submitOrder(book.isbn(), 1).block();

		assertThat(order).isNotNull();
		assertThat(order.status()).isEqualTo(OrderStatus.ACCEPTED);
		assertThat(probe.visibleAtSend).containsExactly(true);
	}

	@TestConfiguration
	static class VisibilityProbe {

		final List<Boolean> visibleAtSend = new CopyOnWriteArrayList<>();

		@Bean
		@GlobalChannelInterceptor(patterns = "acceptOrder-out-0")
		ChannelInterceptor orderVisibilityInterceptor(ObjectMapper objectMapper) {
			return new ChannelInterceptor() {
				@Override
				public Message<?> preSend(Message<?> message, MessageChannel channel) {
					visibleAtSend.add(committed(orderId(objectMapper, message.getPayload())));
					return message;
				}
			};
		}

		private static long orderId(ObjectMapper objectMapper, Object payload) {
			try {
				var json = payload instanceof byte[] bytes
						? objectMapper.readTree(bytes)
						: objectMapper.valueToTree(payload);
				return json.get("orderId").asLong();
			}
			catch (java.io.IOException ex) {
				throw new IllegalStateException(ex);
			}
		}

		private static boolean committed(long orderId) {
			try (var connection = DriverManager.getConnection(postgresql.getJdbcUrl(),
					postgresql.getUsername(), postgresql.getPassword());
				 var statement = connection.prepareStatement("select count(*) from orders where id = ?")) {
				statement.setLong(1, orderId);
				try (var result = statement.executeQuery()) {
					return result.next() && result.getLong(1) == 1;
				}
			}
			catch (SQLException ex) {
				throw new IllegalStateException(ex);
			}
		}

	}

}
