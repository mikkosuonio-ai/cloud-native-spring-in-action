package com.polarbookshop.orderservice.order.domain;

import java.time.Instant;

import com.polarbookshop.orderservice.book.BookClient;
import com.polarbookshop.orderservice.order.event.OrderDispatchedMessage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;
import reactor.test.StepVerifier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class OrderServiceTests {

	@Mock
	private BookClient bookClient;

	@Mock
	private OrderRepository orderRepository;

	private OrderService orderService;

	@BeforeEach
	void setUp() {
		// TODO: Replace this manual construction when upgrading to Mockito 5.
		// Mockito 4 (Spring Boot 2.7) cannot mock the final StreamBridge class, so null is passed
		// instead. It is not used when consuming dispatched events, but any test of submitOrder()
		// would fail. With Mockito 5, mock StreamBridge with @Mock and use @InjectMocks for OrderService.
		orderService = new OrderService(bookClient, null, orderRepository);
	}

	@Test
	void whenOrderDispatchedThenStatusUpdated() {
		var now = Instant.now();
		var acceptedOrder = new Order(394L, "1234567890", "Title - Author", 9.90, 2,
				OrderStatus.ACCEPTED, now, now, "bjorn", "bjorn", 1);
		given(orderRepository.findById(394L)).willReturn(Mono.just(acceptedOrder));
		given(orderRepository.save(any(Order.class)))
				.willAnswer(invocation -> Mono.just(invocation.getArgument(0)));

		StepVerifier.create(orderService.consumeOrderDispatchedEvent(Flux.just(new OrderDispatchedMessage(394L))))
				.assertNext(dispatchedOrder -> {
					assertThat(dispatchedOrder.status()).isEqualTo(OrderStatus.DISPATCHED);
					assertThat(dispatchedOrder)
							.usingRecursiveComparison()
							.ignoringFields("status")
							.isEqualTo(acceptedOrder);
				})
				.verifyComplete();
	}

	@Test
	void whenDispatchedOrderNotExistingThenNothingSaved() {
		given(orderRepository.findById(395L)).willReturn(Mono.empty());

		StepVerifier.create(orderService.consumeOrderDispatchedEvent(Flux.just(new OrderDispatchedMessage(395L))))
				.expectNextCount(0)
				.verifyComplete();

		verify(orderRepository, never()).save(any(Order.class));
	}

}
