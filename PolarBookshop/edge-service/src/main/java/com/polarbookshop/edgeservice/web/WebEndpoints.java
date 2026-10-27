package com.polarbookshop.edgeservice.web;

import java.util.List;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.reactive.function.server.RouterFunction;
import org.springframework.web.reactive.function.server.RouterFunctions;
import org.springframework.web.reactive.function.server.ServerResponse;

@Configuration
public class WebEndpoints {

	@Bean
	public RouterFunction<ServerResponse> routerFunction() {
		return RouterFunctions.route()
				// An empty JSON list, which the SPA shows as a list without books
				.GET("/catalog-fallback", request ->
						ServerResponse.ok().contentType(MediaType.APPLICATION_JSON).bodyValue(List.of()))
				.POST("/catalog-fallback", request ->
						ServerResponse.status(HttpStatus.SERVICE_UNAVAILABLE).build())
				.build();
	}
	
}
