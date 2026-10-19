package com.polarbookshop.orderservice.order.event;

import java.util.function.Consumer;

import com.polarbookshop.orderservice.order.domain.OrderService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import reactor.core.publisher.Flux;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OrderFunctions {

	private static final Logger log = LoggerFactory.getLogger(OrderFunctions.class);

	// Not reactive: an error in a reactive consumer ends its stream, and with it the consumption of
	// every later message. Here an error fails only its own message, which the binder retries and
	// then logs.
	@Bean
	public Consumer<OrderDispatchedMessage> dispatchOrder(OrderService orderService) {
		return message -> orderService.consumeOrderDispatchedEvent(Flux.just(message))
				.doOnNext(order -> log.info("The order with id {} is dispatched", order.id()))
				.blockLast();
	}

}

