NIM ?= nim
NIMFLAGS = -d:release --hints:off

wren: src/*.nim
	$(NIM) c $(NIMFLAGS) -o:wren src/wren.nim

certs:
	./demo/mkcerts.sh

test: wren
	$(NIM) c $(NIMFLAGS) -o:tests/vectors tests/vectors.nim && ./tests/vectors
	$(NIM) c $(NIMFLAGS) -o:tests/oracle tests/oracle.nim && python3 tests/fuzz.py tests/oracle 2000
	./tests/interop.sh
	python3 tests/hellofuzz.py ./wren demo/chain.pem demo/server.key 3000

clean:
	rm -f wren tests/vectors tests/oracle

.PHONY: certs test clean
