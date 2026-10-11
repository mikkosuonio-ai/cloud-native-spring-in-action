package com.polarbookshop.quotefunction.web;

import java.io.IOException;

import javax.servlet.http.HttpServletResponse;

import org.springframework.core.convert.ConversionFailedException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class FunctionInputExceptionHandler {

	// Spring Cloud Function wraps the failure in an IllegalStateException; @ExceptionHandler also matches its cause.
	@ExceptionHandler(ConversionFailedException.class)
	void handleInvalidInput(HttpServletResponse response) throws IOException {
		response.sendError(HttpStatus.BAD_REQUEST.value());
	}

}
