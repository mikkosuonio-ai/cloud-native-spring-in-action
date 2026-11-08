package com.polarbookshop.quotefunction.web;

import java.io.IOException;

import jakarta.servlet.http.HttpServletResponse;
import tools.jackson.core.exc.StreamReadException;
import tools.jackson.databind.exc.MismatchedInputException;

import org.springframework.core.convert.ConversionFailedException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class FunctionInputExceptionHandler {

	// Spring Cloud Function wraps the failure in an IllegalStateException; @ExceptionHandler also
	// matches its causes. A JSON body that can't be read as the input type fails in Jackson 3 since
	// Spring Cloud Function 5 (an unknown genre gave 500): a value that doesn't fit, or JSON that
	// doesn't parse. Errors writing a response stay server errors.
	@ExceptionHandler({ConversionFailedException.class, MismatchedInputException.class, StreamReadException.class})
	void handleInvalidInput(HttpServletResponse response) throws IOException {
		response.sendError(HttpStatus.BAD_REQUEST.value());
	}

}
