package com.polarbookshop.orderservice.order.domain;

import com.polarbookshop.orderservice.book.Book;
import com.polarbookshop.orderservice.book.BookClient;
import com.polarbookshop.orderservice.order.event.OrderAcceptedMessage;
import com.polarbookshop.orderservice.order.event.OrderDispatchedMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import org.springframework.cloud.stream.function.StreamBridge;
import org.springframework.stereotype.Service;

@Service
public class OrderService {

	private static final Logger log = LoggerFactory.getLogger(OrderService.class);

	private final BookClient bookClient;
	private final OrderRepository orderRepository;
	private final StreamBridge streamBridge;

	public OrderService(BookClient bookClient, StreamBridge streamBridge, OrderRepository orderRepository) {
		this.bookClient = bookClient;
		this.orderRepository = orderRepository;
		this.streamBridge = streamBridge;
	}

	public Flux<Order> getAllOrders(String userId) {
		return orderRepository.findAllByCreatedBy(userId);
	}

	// Not @Transactional: the single save commits on its own, so the order-accepted event is only
	// sent once the order is visible. Inside a transaction the event went out before the commit,
	// and dispatcher-service's order-dispatched reply could find no order to update.
	//
	// The trade-off: the order is committed before its event is sent. If the send fails, such as
	// while RabbitMQ is down, the order is marked FAILED, so that it isn't left ACCEPTED for good
	// and a client's retry doesn't add a second ACCEPTED order. The event isn't sent later; that
	// would take a transactional outbox.
	public Mono<Order> submitOrder(String isbn, int quantity) {
		return bookClient.getBookByIsbn(isbn)
				.map(book -> buildAcceptedOrder(book, quantity))
				.defaultIfEmpty(buildRejectedOrder(isbn, quantity))
				.flatMap(orderRepository::save)
				.flatMap(this::publishOrderAcceptedEvent);
	}

	public static Order buildAcceptedOrder(Book book, int quantity) {
		return Order.of(book.isbn(), book.title() + " - " + book.author(),
				book.price(), quantity, OrderStatus.ACCEPTED);
	}

	public static Order buildRejectedOrder(String bookIsbn, int quantity) {
		return Order.of(bookIsbn, null, null, quantity, OrderStatus.REJECTED);
	}

	private Mono<Order> publishOrderAcceptedEvent(Order order) {
		if (!order.status().equals(OrderStatus.ACCEPTED)) {
			return Mono.just(order);
		}
		var orderAcceptedMessage = new OrderAcceptedMessage(order.id());
		log.info("Sending order accepted event with id: {}", order.id());
		try {
			var result = streamBridge.send("acceptOrder-out-0", orderAcceptedMessage);
			log.info("Result of sending data for order with id {}: {}", order.id(), result);
			if (result) {
				return Mono.just(order);
			}
		}
		catch (RuntimeException ex) {
			log.error("Could not send the order accepted event for order {}", order.id(), ex);
		}
		log.warn("Marking order {} as {}", order.id(), OrderStatus.FAILED);
		return orderRepository.save(withStatus(order, OrderStatus.FAILED));
	}

	public Flux<Order> consumeOrderDispatchedEvent(Flux<OrderDispatchedMessage> flux) {
		return flux
				.flatMap(message -> orderRepository.findById(message.orderId()))
				.map(order -> withStatus(order, OrderStatus.DISPATCHED))
				.flatMap(orderRepository::save);
	}

	private static Order withStatus(Order existingOrder, OrderStatus status) {
		return new Order(
				existingOrder.id(),
				existingOrder.bookIsbn(),
				existingOrder.bookName(),
				existingOrder.bookPrice(),
				existingOrder.quantity(),
				status,
				existingOrder.createdDate(),
				existingOrder.lastModifiedDate(),
				existingOrder.createdBy(),
				existingOrder.lastModifiedBy(),
				existingOrder.version()
		);
	}

}
