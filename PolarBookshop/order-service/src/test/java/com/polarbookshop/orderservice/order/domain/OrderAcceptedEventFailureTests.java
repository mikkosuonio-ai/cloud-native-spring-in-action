package com.polarbookshop.orderservice.order.domain;

import java.net.ConnectException;

import com.polarbookshop.orderservice.book.Book;
import com.polarbookshop.orderservice.book.BookClient;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import reactor.core.publisher.Mono;

import org.springframework.amqp.AmqpConnectException;
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
 * An order whose order-accepted event can't be sent is marked FAILED instead of being left
 * ACCEPTED, and the request doesn't fail.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.NONE)
@Import({TestChannelBinderConfiguration.class, OrderAcceptedEventFailureTests.BrokerDown.class})
@Testcontainers
class OrderAcceptedEventFailureTests {

	@Container
	static PostgreSQLContainer<?> postgresql = new PostgreSQLContainer<>(DockerImageName.parse("postgres:17.11"));

	@Autowired
	private OrderService orderService;

	@Autowired
	private OrderRepository orderRepository;

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
	void whenOrderAcceptedEventNotSentThenOrderFailed() {
		var book = new Book("1234567890", "Title", "Author", 9.90);
		given(bookClient.getBookByIsbn(book.isbn())).willReturn(Mono.just(book));

		var order = orderService.submitOrder(book.isbn(), 1).block();

		assertThat(order).isNotNull();
		assertThat(order.status()).isEqualTo(OrderStatus.FAILED);
		var stored = orderRepository.findById(order.id()).block();
		assertThat(stored).isNotNull();
		assertThat(stored.status()).isEqualTo(OrderStatus.FAILED);
	}

	@TestConfiguration
	static class BrokerDown {

		// Fails every send of the order-accepted event, as the Rabbit binder does when RabbitMQ
		// can't be reached.
		@Bean
		@GlobalChannelInterceptor(patterns = "acceptOrder-out-0")
		ChannelInterceptor brokerDownInterceptor() {
			return new ChannelInterceptor() {
				@Override
				public Message<?> preSend(Message<?> message, MessageChannel channel) {
					throw new AmqpConnectException(new ConnectException("Connection refused"));
				}
			};
		}

	}

}
