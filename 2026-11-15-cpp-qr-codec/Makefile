CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -pedantic

SRC = src/main.cpp src/qr.cpp src/png.cpp
HDR = $(wildcard src/*.hpp)

qrforge: $(SRC) $(HDR)
	$(CXX) $(CXXFLAGS) -o $@ $(SRC)

test: qrforge
	./qrforge selftest
	python3 tests/crosscheck.py

clean:
	rm -f qrforge

.PHONY: test clean
