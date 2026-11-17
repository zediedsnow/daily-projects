SRC = rng.ml pq.ml lin.ml raft.ml viz.ml main.ml

quorum: $(SRC)
	ocamlopt -O3 -o $@ $(SRC) 2>/dev/null || ocamlopt -o $@ $(SRC)

test: quorum
	./quorum selftest
	./quorum sweep --seeds 50 --bug all

clean:
	rm -f quorum *.cm[iox] *.o

.PHONY: test clean
