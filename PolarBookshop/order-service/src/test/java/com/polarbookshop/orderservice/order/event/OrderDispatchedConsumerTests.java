package com.polarbookshop.orderservice.order.event;

import com.polarbookshop.orderservice.order.domain.Order;
import com.polarbookshop.orderservice.order.domain.OrderRepository;
import com.polarbookshop.orderservice.order.domain.OrderStatus;
import org.junit.jupiter.api.Test;
import reactor.core.publisher.Mono;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.cloud.stream.binder.test.InputDestination;
import org.springframework.cloud.stream.binder.test.TestChannelBinderConfiguration;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;

import static org.assertj.core.api.Assertions.catchThrowable;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

/**
 * A failure to update one dispatched order doesn't stop the consumer: the next order-dispatched
 * message is still consumed. The repository is a mock, so no database is needed.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.NONE, properties = "spring.flyway.enabled=false")
@Import(TestChannelBinderConfiguration.class)
class OrderDispatchedConsumerTests {

	@Autowired
	private InputDestination input;

	@MockBean
	private OrderRepository orderRepository;

	// SecurityConfig needs one; without a web server, no token is ever decoded.
	@MockBean
	private ReactiveJwtDecoder jwtDecoder;

	@Test
	void whenUpdatingAnOrderFailsThenLaterOrdersAreStillDispatched() {
		given(orderRepository.findById(1L))
				.willReturn(Mono.error(new DataAccessResourceFailureException("PostgreSQL is down")));
		given(orderRepository.findById(2L)).willReturn(Mono.just(acceptedOrder(2L)));
		given(orderRepository.save(any(Order.class))).willAnswer(invocation -> Mono.just(invocation.getArgument(0)));

		// The binder retries the message and logs its failure. Another binder might pass the failure on
		// to the sender instead.
		catchThrowable(() -> input.send(MessageBuilder.withPayload(new OrderDispatchedMessage(1L)).build(),
				"order-dispatched"));
		input.send(MessageBuilder.withPayload(new OrderDispatchedMessage(2L)).build(), "order-dispatched");

		// Three attempts, the binder's default.
		verify(orderRepository, times(3)).findById(1L);
		verify(orderRepository).save(argThat(order -> order.id() == 2L && order.status() == OrderStatus.DISPATCHED));
	}

	private static Order acceptedOrder(Long id) {
		return new Order(id, "1234567890", "Title - Author", 9.90, 1, OrderStatus.ACCEPTED,
				null, null, null, null, 0);
	}

}
