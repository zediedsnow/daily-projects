# Kestrel — a chess engine in one C file

Kestrel is a complete chess engine in about 900 lines of dependency-free C99. It has fully legal move generation, an alpha-beta search with the standard modern pruning tricks, a tapered evaluation, and a **UCI interface**, so you can load it into Arena, Cute Chess, BanksiaGUI or any other chess GUI and play it. It also has a terminal mode for playing against it directly.

## Why it's interesting

Chess engines are a good exercise in getting details right. One bug in en passant or castling-through-check ruins everything after it, and a search is only fast if the move ordering, hashing and pruning all fit together. Kestrel:

- **Passes the standard perft suite.** It counts every node of the legal move tree on six well-known test positions (including the infamous *Kiwipete* and the promotion/en passant traps) and matches the published counts exactly: 41.8 million nodes in about 1.4 seconds.
- **Searches about 2.5 million nodes/second** on one core and reaches depth 12–13 from the opening in under a second.
- **Finds tactics.** It finds Légal-style mates and back-rank mates in milliseconds.
- **Plays coherent games.** It develops pieces, castles, trades into endgames, promotes pawns and handles queen-vs-rook endings.

## Build & run

```sh
make            # builds ./kestrel (any C99 compiler: gcc, clang)
make test       # perft correctness suite
make bench      # fixed-depth search benchmark

./kestrel play w 2000                # play White vs the engine, 2 s per engine move
./kestrel play b 2000                # play Black
./kestrel selfplay 300 80            # engine vs itself, 300 ms/move, prints the game in SAN
./kestrel solve "<FEN>" 10           # analyse a position to depth 10
./kestrel perft 5 "<FEN>"            # divide-perft for debugging
./kestrel uci                        # UCI mode (the default) - point your GUI at ./kestrel
```

In play mode you enter moves in coordinate notation: `e2e4`, `g1f3`, `e1g1` (castling), `e7e8q` (promotion).

## Sample output

### Perft suite (`make test`)

```
start position           depth 5       4865609  OK    (165 ms)
kiwipete                 depth 4       4085603  OK    (137 ms)
rook endgame / ep pins   depth 6      11030083  OK    (521 ms)
promotions + castling    depth 5      15833292  OK    (446 ms)
underpromotion           depth 4       2103487  OK    (59 ms)
middlegame               depth 4       3894594  OK    (91 ms)

41812668 nodes in 1419 ms (29.5 Mnps) - all perft tests passed
```

### Solving a mate in 2 (Légal's trap pattern)

```
$ ./kestrel solve "r2qkb1r/pp2nppp/3p4/2pNN1B1/2BnP3/3P4/PPP2PPP/R2bK2R w KQkq - 1 1" 8

  8  r : . q k b . r
  7  p p : . n p p p
  6  . : . p . : . :
  5  : . p N N . B .
  4  . : B n P : . :
  3  : . : P : . : .
  2  P P P : . P P P
  1  R . : b K . : R

     a b c d e f g h     White to move

info depth 1 score cp -741 nodes 170 time 0 nps 170 pv e5f7
info depth 2 score mate 2 nodes 686 time 0 nps 686 pv d5f6 g7f6 c4f7
info depth 4 score mate 2 nodes 3491 time 3 nps 1163666 pv d5f6 g7f6 c4f7

best move: Nf6+  (mate in 2)
```

White is down a queen, but Nf6+ gxf6 Bxf7# is mate.

### UCI session

```
> position startpos moves e2e4 e7e5
> go movetime 1000
info depth 12 score cp 15 nodes 1181973 time 427 nps 2768086 pv g1f3 b8c6 d2d4 e5d4 f3d4 c6d4 d1d4 g8f6 b1c3 c7c5 d4e5 f8e7 c1e3
info depth 13 score cp 14 nodes 1919486 time 701 nps 2738211 pv g1f3 b8c6 d2d4 e5d4 f3d4 c6d4 d1d4 g8f6 b1c3 f8e7 f1d3 c7c5 d4e5
bestmove g1f3
```

### Self-play at 150 ms/move (opening and endgame excerpts)

```
1. e4 e5 2. Nf3 Nc6 3. Nc3 Nf6 4. d4 exd4 5. Nxd4 d5 6. exd5 Nxd5
7. Bb5 Nxc3 8. bxc3 Bd7 9. O-O Nxd4 10. Bxd7+ Qxd7 11. Qxd4 Qxd4
12. Re1+ Kd7 13. cxd4 Bd6 14. Be3 Rhe8 15. d5 a5 ...
... 50. Rxc7+ Ke8 51. g6 Rxh6 52. Rc8+ Kd7 53. g7 Re6+ 54. Kf3 Rf6+
55. Ke4 Kxc8 56. g8=Q+ Kd7 57. Qb3 Re6+ ...
```

## How it works

**Board.** A 10×12 *mailbox* array. The 8×8 board sits inside a border of `OFF` squares, so sliding pieces stop at the edge without any bounds checks. Pieces are 4-bit codes: low 3 bits for the type, bit 3 for the colour.

**Move generation.** Moves are generated pseudo-legally, then `make()` plays each one and rejects it if the mover's own king is left in check. Castling checks that the king's start, transit and destination squares are not attacked. Moves are packed into 32 bits: from, to, promotion piece and a flag for en passant, castling or a double push.

**Hashing.** 64-bit Zobrist keys are updated incrementally on every make/unmake. They drive the transposition table (1M entries) and repetition detection.

**Search.** Iterative-deepening negamax with alpha-beta and:

- *Principal Variation Search*: after the first move, the rest are searched with a null window and re-searched only if they beat alpha.
- *Transposition table* cutoffs, plus searching the TT move first.
- *Null-move pruning* (R = 2 + depth/4), turned off in check and in pawn-only endings where zugzwang is common.
- *Late-move reductions* for quiet moves searched late in the move list.
- *Check extensions*, so forcing lines are searched deeper.
- *Quiescence search* over captures, with delta pruning, which avoids the horizon effect.
- *Move ordering*: TT move, then captures by MVV-LVA (most valuable victim, least valuable attacker), promotions, two killer moves per ply, and the history heuristic.
- Mate scores are adjusted by ply when stored in the TT, so "mate in N" stays correct across transpositions.

**Evaluation.** Material plus *PeSTO* piece-square tables, with separate middlegame and endgame values. The two are blended by a game-phase counter based on the remaining non-pawn material. That is why the king hides in the middlegame and walks to the centre in endgames. There is also a bishop-pair bonus and a small tempo bonus.

**Draws.** Threefold repetition, the 50-move rule, stalemate and insufficient material are all detected.
