package com.polarbookshop.orderservice.order.domain;

public enum OrderStatus {
	ACCEPTED,
	REJECTED,
	DISPATCHED,
	// Accepted, but its order-accepted event couldn't be sent, so it won't be dispatched.
	FAILED
}
