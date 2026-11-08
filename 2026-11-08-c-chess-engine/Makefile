CC ?= cc
CFLAGS ?= -O3 -march=native -Wall -Wextra -std=c99 -D_DEFAULT_SOURCE

kestrel: chess.c
	$(CC) $(CFLAGS) -o $@ $<

test: kestrel
	./kestrel perft

bench: kestrel
	./kestrel bench

clean:
	rm -f kestrel

.PHONY: test bench clean
