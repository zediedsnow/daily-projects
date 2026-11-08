/*
 * Kestrel - a small but serious chess engine in a single C file.
 *
 *   - 10x12 mailbox board, fully legal move generation
 *     (castling, en passant, promotions, check detection)
 *   - Zobrist hashing + transposition table
 *   - Negamax alpha-beta with PVS, iterative deepening, aspiration-free
 *     null-move pruning, late-move reductions, check extensions
 *   - Quiescence search with MVV-LVA capture ordering
 *   - Killer + history heuristics
 *   - Tapered evaluation (PeSTO-style middlegame / endgame tables)
 *   - Repetition and 50-move draw detection
 *   - UCI protocol, so it plugs into any chess GUI
 *   - perft test suite, terminal play mode, self-play, puzzle solver
 *
 * Build: cc -O2 -o kestrel chess.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>

/* ---------------------------------------------------------------- pieces */
enum { EMPTY = 0, PAWN = 1, KNIGHT, BISHOP, ROOK, QUEEN, KING, OFF = 7 };
#define WHITE 0
#define BLACK 8
#define TYPE(p) ((p) & 7)
#define COLOR(p) ((p) & 8)

/* squares in 10x12 mailbox: a1 = 21, h1 = 28, a8 = 91, h8 = 98 */
#define SQ(f, r) (21 + (f) + (r) * 10)
#define FILE_OF(s) (((s) - 21) % 10)
#define RANK_OF(s) (((s) - 21) / 10)

typedef uint32_t Move;
#define M_FROM(m) ((m) & 127)
#define M_TO(m) (((m) >> 7) & 127)
#define M_PROMO(m) (((m) >> 14) & 7)
#define M_FLAG(m) (((m) >> 17) & 7)
#define MK(f, t, p, fl) ((Move)(f) | ((Move)(t) << 7) | ((Move)(p) << 14) | ((Move)(fl) << 17))
enum { F_NONE = 0, F_EP = 1, F_CASTLE = 2, F_DOUBLE = 3 };

enum { CW_K = 1, CW_Q = 2, CB_K = 4, CB_Q = 8 };

static const int N_DIR[8] = { -21, -19, -12, -8, 8, 12, 19, 21 };
static const int K_DIR[8] = { -11, -10, -9, -1, 1, 9, 10, 11 };
static const int B_DIR[4] = { -11, -9, 9, 11 };
static const int R_DIR[4] = { -10, -1, 1, 10 };

/* ---------------------------------------------------------------- state */
#define MAX_PLY 128
#define MAX_HIST 1024

typedef struct {
    Move move;
    int captured, castle, ep, half;
    uint64_t hash;
} Undo;

static int board[120];
static int side, castle, ep, half, king_sq[2];
static uint64_t hash;
static Undo undo_stack[MAX_HIST];
static uint64_t hist_hash[MAX_HIST];
static int hply;
static int castle_mask[120];

static uint64_t Z_PIECE[16][120], Z_SIDE, Z_CASTLE[16], Z_EP[120];

static uint64_t rng_state = 0x9E3779B97F4A7C15ULL;
static uint64_t rand64(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static void init_tables(void) {
    for (int p = 0; p < 16; p++)
        for (int s = 0; s < 120; s++) Z_PIECE[p][s] = rand64();
    Z_SIDE = rand64();
    for (int i = 0; i < 16; i++) Z_CASTLE[i] = rand64();
    for (int s = 0; s < 120; s++) Z_EP[s] = rand64();
    for (int s = 0; s < 120; s++) castle_mask[s] = 15;
    castle_mask[SQ(4, 0)] &= ~(CW_K | CW_Q);
    castle_mask[SQ(7, 0)] &= ~CW_K;
    castle_mask[SQ(0, 0)] &= ~CW_Q;
    castle_mask[SQ(4, 7)] &= ~(CB_K | CB_Q);
    castle_mask[SQ(7, 7)] &= ~CB_K;
    castle_mask[SQ(0, 7)] &= ~CB_Q;
}

static uint64_t compute_hash(void) {
    uint64_t h = 0;
    for (int s = 21; s < 99; s++)
        if (board[s] != OFF && board[s] != EMPTY) h ^= Z_PIECE[board[s]][s];
    if (side == BLACK) h ^= Z_SIDE;
    h ^= Z_CASTLE[castle];
    if (ep) h ^= Z_EP[ep];
    return h;
}

static const char *PIECE_CH = ".PNBRQK?.pnbrqk?";

static int set_fen(const char *fen) {
    for (int i = 0; i < 120; i++) board[i] = OFF;
    for (int r = 0; r < 8; r++)
        for (int f = 0; f < 8; f++) board[SQ(f, r)] = EMPTY;
    int f = 0, r = 7;
    const char *p = fen;
    for (; *p && *p != ' '; p++) {
        if (*p == '/') { r--; f = 0; continue; }
        if (*p >= '1' && *p <= '8') { f += *p - '0'; continue; }
        const char *c = strchr(PIECE_CH, *p);
        if (!c || f > 7 || r < 0) return 0;
        int pc = (int)(c - PIECE_CH);
        board[SQ(f, r)] = pc;
        if (TYPE(pc) == KING) king_sq[COLOR(pc) >> 3] = SQ(f, r);
        f++;
    }
    while (*p == ' ') p++;
    side = (*p == 'b') ? BLACK : WHITE;
    if (*p) p++;
    while (*p == ' ') p++;
    castle = 0;
    for (; *p && *p != ' '; p++) {
        if (*p == 'K') castle |= CW_K;
        if (*p == 'Q') castle |= CW_Q;
        if (*p == 'k') castle |= CB_K;
        if (*p == 'q') castle |= CB_Q;
    }
    while (*p == ' ') p++;
    ep = 0;
    if (*p && *p != '-') { ep = SQ(p[0] - 'a', p[1] - '1'); p += 2; }
    else if (*p) p++;
    half = 0;
    if (*p) half = atoi(p);
    hply = 0;
    hash = compute_hash();
    return 1;
}

#define START_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

/* -------------------------------------------------------------- attacks */
static int attacked(int sq, int by) {
    /* pawns */
    int pd = (by == WHITE) ? -10 : 10;
    if (board[sq + pd - 1] == (PAWN | by) || board[sq + pd + 1] == (PAWN | by)) return 1;
    for (int i = 0; i < 8; i++) {
        if (board[sq + N_DIR[i]] == (KNIGHT | by)) return 1;
        if (board[sq + K_DIR[i]] == (KING | by)) return 1;
    }
    for (int i = 0; i < 4; i++) {
        int s = sq + B_DIR[i];
        while (board[s] == EMPTY) s += B_DIR[i];
        if (board[s] == (BISHOP | by) || board[s] == (QUEEN | by)) return 1;
        s = sq + R_DIR[i];
        while (board[s] == EMPTY) s += R_DIR[i];
        if (board[s] == (ROOK | by) || board[s] == (QUEEN | by)) return 1;
    }
    return 0;
}

static int in_check(void) { return attacked(king_sq[side >> 3], side ^ BLACK); }

/* ------------------------------------------------------------- movegen */
typedef struct { Move m[256]; int score[256]; int n; } MoveList;

static void add_pawn_move(MoveList *l, int from, int to, int flag) {
    int r = RANK_OF(to);
    if (r == 0 || r == 7) {
        for (int p = QUEEN; p >= KNIGHT; p--) l->m[l->n++] = MK(from, to, p, flag);
    } else l->m[l->n++] = MK(from, to, 0, flag);
}

static void gen_moves(MoveList *l, int captures_only) {
    l->n = 0;
    int us = side, them = side ^ BLACK;
    int fwd = (us == WHITE) ? 10 : -10;
    int start_rank = (us == WHITE) ? 1 : 6;
    for (int s = 21; s < 99; s++) {
        int pc = board[s];
        if (pc == EMPTY || pc == OFF || COLOR(pc) != us) continue;
        int t = TYPE(pc);
        if (t == PAWN) {
            int to = s + fwd;
            if (board[to] == EMPTY) {
                int r = RANK_OF(to);
                if (!captures_only || r == 0 || r == 7) add_pawn_move(l, s, to, F_NONE);
                if (!captures_only && RANK_OF(s) == start_rank && board[to + fwd] == EMPTY)
                    l->m[l->n++] = MK(s, to + fwd, 0, F_DOUBLE);
            }
            for (int d = -1; d <= 1; d += 2) {
                int c = s + fwd + d;
                if (board[c] != OFF && board[c] != EMPTY && COLOR(board[c]) == them)
                    add_pawn_move(l, s, c, F_NONE);
                else if (c == ep && ep) l->m[l->n++] = MK(s, c, 0, F_EP);
            }
            continue;
        }
        const int *dirs; int nd, slide;
        switch (t) {
            case KNIGHT: dirs = N_DIR; nd = 8; slide = 0; break;
            case BISHOP: dirs = B_DIR; nd = 4; slide = 1; break;
            case ROOK:   dirs = R_DIR; nd = 4; slide = 1; break;
            case QUEEN:  dirs = K_DIR; nd = 8; slide = 1; break;
            default:     dirs = K_DIR; nd = 8; slide = 0; break;
        }
        for (int i = 0; i < nd; i++) {
            int to = s + dirs[i];
            while (board[to] != OFF) {
                if (board[to] == EMPTY) {
                    if (!captures_only) l->m[l->n++] = MK(s, to, 0, F_NONE);
                } else {
                    if (COLOR(board[to]) == them) l->m[l->n++] = MK(s, to, 0, F_NONE);
                    break;
                }
                if (!slide) break;
                to += dirs[i];
            }
        }
    }
    if (captures_only) return;
    /* castling */
    if (us == WHITE) {
        if ((castle & CW_K) && board[SQ(5,0)] == EMPTY && board[SQ(6,0)] == EMPTY &&
            !attacked(SQ(4,0), them) && !attacked(SQ(5,0), them) && !attacked(SQ(6,0), them))
            l->m[l->n++] = MK(SQ(4,0), SQ(6,0), 0, F_CASTLE);
        if ((castle & CW_Q) && board[SQ(3,0)] == EMPTY && board[SQ(2,0)] == EMPTY && board[SQ(1,0)] == EMPTY &&
            !attacked(SQ(4,0), them) && !attacked(SQ(3,0), them) && !attacked(SQ(2,0), them))
            l->m[l->n++] = MK(SQ(4,0), SQ(2,0), 0, F_CASTLE);
    } else {
        if ((castle & CB_K) && board[SQ(5,7)] == EMPTY && board[SQ(6,7)] == EMPTY &&
            !attacked(SQ(4,7), them) && !attacked(SQ(5,7), them) && !attacked(SQ(6,7), them))
            l->m[l->n++] = MK(SQ(4,7), SQ(6,7), 0, F_CASTLE);
        if ((castle & CB_Q) && board[SQ(3,7)] == EMPTY && board[SQ(2,7)] == EMPTY && board[SQ(1,7)] == EMPTY &&
            !attacked(SQ(4,7), them) && !attacked(SQ(3,7), them) && !attacked(SQ(2,7), them))
            l->m[l->n++] = MK(SQ(4,7), SQ(2,7), 0, F_CASTLE);
    }
}

/* ---------------------------------------------------------- make/unmake */
static inline void put(int s, int pc) { board[s] = pc; hash ^= Z_PIECE[pc][s]; }
static inline void lift(int s) { hash ^= Z_PIECE[board[s]][s]; board[s] = EMPTY; }

static void unmake(void);

static int make(Move m) {
    int from = M_FROM(m), to = M_TO(m), promo = M_PROMO(m), flag = M_FLAG(m);
    Undo *u = &undo_stack[hply];
    u->move = m; u->castle = castle; u->ep = ep; u->half = half; u->hash = hash;
    hist_hash[hply] = hash;
    int pc = board[from];
    int us = side, them = side ^ BLACK;
    u->captured = board[to];
    half++;
    if (board[to] != EMPTY) { lift(to); half = 0; }
    lift(from);
    put(to, promo ? (promo | us) : pc);
    if (TYPE(pc) == PAWN) half = 0;
    if (flag == F_EP) {
        int cs = to + (us == WHITE ? -10 : 10);
        u->captured = board[cs];
        lift(cs);
    } else if (flag == F_CASTLE) {
        int rf, rt;
        if (to > from) { rf = from + 3; rt = from + 1; } else { rf = from - 4; rt = from - 1; }
        int rk = board[rf]; lift(rf); put(rt, rk);
    }
    if (TYPE(pc) == KING) king_sq[us >> 3] = to;
    hash ^= Z_CASTLE[castle];
    castle &= castle_mask[from] & castle_mask[to];
    hash ^= Z_CASTLE[castle];
    if (ep) hash ^= Z_EP[ep];
    ep = (flag == F_DOUBLE) ? (from + to) / 2 : 0;
    if (ep) hash ^= Z_EP[ep];
    side = them;
    hash ^= Z_SIDE;
    hply++;
    if (attacked(king_sq[us >> 3], them)) { unmake(); return 0; }
    return 1;
}

static void unmake(void) {
    hply--;
    Undo *u = &undo_stack[hply];
    Move m = u->move;
    int from = M_FROM(m), to = M_TO(m), promo = M_PROMO(m), flag = M_FLAG(m);
    side ^= BLACK;
    int us = side;
    int pc = promo ? (PAWN | us) : board[to];
    board[from] = pc;
    board[to] = EMPTY;
    if (flag == F_EP) board[to + (us == WHITE ? -10 : 10)] = u->captured;
    else board[to] = u->captured;
    if (flag == F_CASTLE) {
        int rf, rt;
        if (to > from) { rf = from + 3; rt = from + 1; } else { rf = from - 4; rt = from - 1; }
        board[rf] = board[rt]; board[rt] = EMPTY;
    }
    if (TYPE(pc) == KING) king_sq[us >> 3] = from;
    castle = u->castle; ep = u->ep; half = u->half; hash = u->hash;
}

/* null move: pass the turn (used by null-move pruning) */
static void make_null(void) {
    Undo *u = &undo_stack[hply];
    u->move = 0; u->castle = castle; u->ep = ep; u->half = half; u->hash = hash; u->captured = EMPTY;
    hist_hash[hply] = hash;
    if (ep) hash ^= Z_EP[ep];
    ep = 0; half++;
    side ^= BLACK; hash ^= Z_SIDE;
    hply++;
}
static void unmake_null(void) {
    hply--;
    Undo *u = &undo_stack[hply];
    side ^= BLACK;
    castle = u->castle; ep = u->ep; half = u->half; hash = u->hash;
}

/* ---------------------------------------------------------------- perft */
static uint64_t perft(int depth) {
    if (depth == 0) return 1;
    MoveList l; gen_moves(&l, 0);
    uint64_t n = 0;
    for (int i = 0; i < l.n; i++) {
        if (!make(l.m[i])) continue;
        n += perft(depth - 1);
        unmake();
    }
    return n;
}

/* ----------------------------------------------------------- notation */
static void sq_str(int s, char *o) { o[0] = 'a' + FILE_OF(s); o[1] = '1' + RANK_OF(s); o[2] = 0; }

static const char *move_str(Move m) {
    static char buf[4][8]; static int k = 0;
    char *b = buf[k++ & 3];
    if (!m) { strcpy(b, "0000"); return b; }
    sq_str(M_FROM(m), b); sq_str(M_TO(m), b + 2);
    if (M_PROMO(m)) { b[4] = "  nbrq"[M_PROMO(m)]; b[5] = 0; }
    return b;
}

static Move parse_move(const char *s) {
    MoveList l; gen_moves(&l, 0);
    for (int i = 0; i < l.n; i++) {
        const char *ms = move_str(l.m[i]);
        size_t len = strlen(ms);
        if (strncmp(ms, s, len) == 0 && (s[len] == 0 || s[len] == ' ' || s[len] == '\n' || s[len] == '\r')) {
            if (make(l.m[i])) { unmake(); return l.m[i]; }
        }
        /* accept "e7e8" as queen promotion */
        if (M_PROMO(l.m[i]) == QUEEN && strlen(s) >= 4 && strncmp(ms, s, 4) == 0 &&
            (s[4] == 0 || s[4] == ' ' || s[4] == '\n')) {
            if (make(l.m[i])) { unmake(); return l.m[i]; }
        }
    }
    return 0;
}

/* Standard Algebraic Notation, for human-friendly game records */
static const char *san(Move m) {
    static char buf[16];
    int from = M_FROM(m), to = M_TO(m), pc = board[from], t = TYPE(pc);
    char *b = buf; char sq[3];
    if (M_FLAG(m) == F_CASTLE) { strcpy(b, to > from ? "O-O" : "O-O-O"); b += strlen(b); }
    else {
        int cap = board[to] != EMPTY || M_FLAG(m) == F_EP;
        if (t == PAWN) {
            if (cap) { *b++ = 'a' + FILE_OF(from); *b++ = 'x'; }
            sq_str(to, sq); *b++ = sq[0]; *b++ = sq[1];
            if (M_PROMO(m)) { *b++ = '='; *b++ = " PNBRQK"[M_PROMO(m)]; }
        } else {
            *b++ = " PNBRQK"[t];
            MoveList l; gen_moves(&l, 0);
            int amb = 0, same_file = 0, same_rank = 0;
            for (int i = 0; i < l.n; i++) {
                Move o = l.m[i];
                if (o == m || (int)M_TO(o) != to || board[M_FROM(o)] != pc) continue;
                if (!make(o)) continue;
                unmake();
                amb = 1;
                if ((int)FILE_OF(M_FROM(o)) == FILE_OF(from)) same_file = 1;
                if ((int)RANK_OF(M_FROM(o)) == RANK_OF(from)) same_rank = 1;
            }
            if (amb) {
                if (!same_file) *b++ = 'a' + FILE_OF(from);
                else if (!same_rank) *b++ = '1' + RANK_OF(from);
                else { *b++ = 'a' + FILE_OF(from); *b++ = '1' + RANK_OF(from); }
            }
            if (cap) *b++ = 'x';
            sq_str(to, sq); *b++ = sq[0]; *b++ = sq[1];
        }
    }
    if (make(m)) {
        if (in_check()) {
            MoveList l; gen_moves(&l, 0); int legal = 0;
            for (int i = 0; i < l.n && !legal; i++) if (make(l.m[i])) { legal = 1; unmake(); }
            *b++ = legal ? '+' : '#';
        }
        unmake();
    }
    *b = 0;
    return buf;
}

/* ----------------------------------------------------------- evaluation */
/* PeSTO piece-square tables (Ronald Friederich), a8 = index 0 */
static const int MG_VAL[7] = { 0, 82, 337, 365, 477, 1025, 0 };
static const int EG_VAL[7] = { 0, 94, 281, 297, 512, 936, 0 };
static const int PHASE_INC[7] = { 0, 0, 1, 1, 2, 4, 0 };

static const int MG_PST[7][64] = {
 {0},
 { 0,0,0,0,0,0,0,0, 98,134,61,95,68,126,34,-11, -6,7,26,31,65,56,25,-20, -14,13,6,21,23,12,17,-23,
   -27,-2,-5,12,17,6,10,-25, -26,-4,-4,-10,3,3,33,-12, -35,-1,-20,-23,-15,24,38,-22, 0,0,0,0,0,0,0,0 },
 { -167,-89,-34,-49,61,-97,-15,-107, -73,-41,72,36,23,62,7,-17, -47,60,37,65,84,129,73,44, -9,17,19,53,37,69,18,22,
   -13,4,16,13,28,19,21,-8, -23,-9,12,10,19,17,25,-16, -29,-53,-12,-3,-1,18,-14,-19, -105,-21,-58,-33,-17,-28,-19,-23 },
 { -29,4,-82,-37,-25,-42,7,-8, -26,16,-18,-13,30,59,18,-47, -16,37,43,40,35,50,37,-2, -4,5,19,50,37,37,7,-2,
   -6,13,13,26,34,12,10,4, 0,15,15,15,14,27,18,10, 4,15,16,0,7,21,33,1, -33,-3,-14,-21,-13,-12,-39,-21 },
 { 32,42,32,51,63,9,31,43, 27,32,58,62,80,67,26,44, -5,19,26,36,17,45,61,16, -24,-11,7,26,24,35,-8,-20,
   -36,-26,-12,-1,9,-7,6,-23, -45,-25,-16,-17,3,0,-5,-33, -44,-16,-20,-9,-1,11,-6,-71, -19,-13,1,17,16,7,-37,-26 },
 { -28,0,29,12,59,44,43,45, -24,-39,-5,1,-16,57,28,54, -13,-17,7,8,29,56,47,57, -27,-27,-16,-16,-1,17,-2,1,
   -9,-26,-9,-10,-2,-4,3,-3, -14,2,-11,-2,-5,2,14,5, -35,-8,11,2,8,15,-3,1, -1,-18,-9,10,-15,-25,-31,-50 },
 { -65,23,16,-15,-56,-34,2,13, 29,-1,-20,-7,-8,-4,-38,-29, -9,24,2,-16,-20,6,22,-22, -17,-20,-12,-27,-30,-25,-14,-36,
   -49,-1,-27,-39,-46,-44,-33,-51, -14,-14,-22,-46,-44,-30,-15,-27, 1,7,-8,-64,-43,-16,9,8, -15,36,12,-54,8,-28,24,14 },
};
static const int EG_PST[7][64] = {
 {0},
 { 0,0,0,0,0,0,0,0, 178,173,158,134,147,132,165,187, 94,100,85,67,56,53,82,84, 32,24,13,5,-2,4,17,17,
   13,9,-3,-7,-7,-8,3,-1, 4,7,-6,1,0,-5,-1,-8, 13,8,8,10,13,0,2,-7, 0,0,0,0,0,0,0,0 },
 { -58,-38,-13,-28,-31,-27,-63,-99, -25,-8,-25,-2,-9,-25,-24,-52, -24,-20,10,9,-1,-9,-19,-41, -17,3,22,22,22,11,8,-18,
   -18,-6,16,25,16,17,4,-18, -23,-3,-1,15,10,-3,-20,-22, -42,-20,-10,-5,-2,-20,-23,-44, -29,-51,-23,-15,-22,-18,-50,-64 },
 { -14,-21,-11,-8,-7,-9,-17,-24, -8,-4,7,-12,-3,-13,-4,-14, 2,-8,0,-1,-2,6,0,4, -3,9,12,9,14,10,3,2,
   -6,3,13,19,7,10,-3,-9, -12,-3,8,10,13,3,-7,-15, -14,-18,-7,-1,4,-9,-15,-27, -23,-9,-23,-5,-9,-16,-5,-17 },
 { 13,10,18,15,12,12,8,5, 11,13,13,11,-3,3,8,3, 7,7,7,5,4,-3,-5,-3, 4,3,13,1,2,1,-1,2,
   3,5,8,4,-5,-6,-8,-11, -4,0,-5,-1,-7,-12,-8,-16, -6,-6,0,2,-9,-9,-11,-3, -9,2,3,-1,-5,-13,4,-20 },
 { -9,22,22,27,27,19,10,20, -17,20,32,41,58,25,30,0, -20,6,9,49,47,35,19,9, 3,22,24,45,57,40,57,36,
   -18,28,19,47,31,34,39,23, -16,-27,15,6,9,17,10,5, -22,-23,-30,-16,-16,-23,-36,-32, -33,-28,-22,-43,-5,-32,-20,-41 },
 { -74,-35,-18,-18,-11,15,4,-17, -12,17,14,17,17,38,23,11, 10,17,23,15,20,45,44,13, -8,22,24,27,26,33,26,3,
   -18,-4,21,24,27,23,9,-11, -19,-3,11,21,23,16,7,-9, -27,-11,4,13,14,4,-5,-17, -53,-34,-21,-11,-28,-14,-24,-43 },
};

static int evaluate(void) {
    int mg[2] = { 0, 0 }, eg[2] = { 0, 0 }, phase = 0;
    int bishops[2] = { 0, 0 };
    for (int s = 21; s < 99; s++) {
        int pc = board[s];
        if (pc == EMPTY || pc == OFF) continue;
        int t = TYPE(pc), c = COLOR(pc) >> 3;
        int f = FILE_OF(s), r = RANK_OF(s);
        int idx = c == 0 ? (7 - r) * 8 + f : r * 8 + f;
        mg[c] += MG_VAL[t] + MG_PST[t][idx];
        eg[c] += EG_VAL[t] + EG_PST[t][idx];
        phase += PHASE_INC[t];
        if (t == BISHOP) bishops[c]++;
    }
    for (int c = 0; c < 2; c++) if (bishops[c] >= 2) { mg[c] += 30; eg[c] += 50; }
    if (phase > 24) phase = 24;
    int us = side >> 3, them = us ^ 1;
    int m = mg[us] - mg[them], e = eg[us] - eg[them];
    return (m * phase + e * (24 - phase)) / 24 + 10; /* +10 tempo */
}

/* --------------------------------------------------------------- search */
#define INF 32000
#define MATE 31000
#define IS_MATE(s) ((s) > MATE - MAX_PLY || (s) < -MATE + MAX_PLY)

typedef struct { uint64_t key; Move move; int16_t score; int8_t depth; uint8_t flag; } TTEntry;
enum { TT_EXACT = 1, TT_LOWER = 2, TT_UPPER = 3 };
#define TT_BITS 20
static TTEntry *tt;

static Move killers[MAX_PLY][2];
static int history[16][120];
static uint64_t nodes;
static int stop_search;
static long long t_start, t_limit;
static Move pv_table[MAX_PLY][MAX_PLY];
static int pv_len[MAX_PLY];

static long long now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void check_time(void) {
    if ((nodes & 2047) == 0 && t_limit > 0 && now_ms() - t_start >= t_limit) stop_search = 1;
}

static int is_repetition(void) {
    for (int i = hply - 2; i >= 0 && i >= hply - half; i -= 2)
        if (hist_hash[i] == hash) return 1;
    return 0;
}

static void score_moves(MoveList *l, Move tt_move, int ply) {
    for (int i = 0; i < l->n; i++) {
        Move m = l->m[i];
        int victim = TYPE(board[M_TO(m)]);
        if (M_FLAG(m) == F_EP) victim = PAWN;
        int attacker = TYPE(board[M_FROM(m)]);
        int sc;
        if (m == tt_move) sc = 2000000;
        else if (victim) sc = 1000000 + victim * 100 - attacker;
        else if (M_PROMO(m)) sc = 950000 + M_PROMO(m);
        else if (m == killers[ply][0]) sc = 900000;
        else if (m == killers[ply][1]) sc = 899000;
        else sc = history[board[M_FROM(m)]][M_TO(m)];
        l->score[i] = sc;
    }
}

static Move pick_next(MoveList *l, int i) {
    int best = i;
    for (int j = i + 1; j < l->n; j++) if (l->score[j] > l->score[best]) best = j;
    Move m = l->m[best]; int s = l->score[best];
    l->m[best] = l->m[i]; l->score[best] = l->score[i];
    l->m[i] = m; l->score[i] = s;
    return m;
}

static int quiesce(int alpha, int beta, int ply) {
    nodes++; check_time();
    if (stop_search) return 0;
    int stand = evaluate();
    if (ply >= MAX_PLY - 1) return stand;
    if (stand >= beta) return stand;
    if (stand > alpha) alpha = stand;
    MoveList l; gen_moves(&l, 1);
    score_moves(&l, 0, ply);
    for (int i = 0; i < l.n; i++) {
        Move m = pick_next(&l, i);
        /* delta pruning: even winning this piece cannot raise alpha */
        int victim = M_FLAG(m) == F_EP ? PAWN : TYPE(board[M_TO(m)]);
        if (!M_PROMO(m) && stand + MG_VAL[victim] + 200 < alpha) continue;
        if (!make(m)) continue;
        int sc = -quiesce(-beta, -alpha, ply + 1);
        unmake();
        if (stop_search) return 0;
        if (sc > alpha) { alpha = sc; if (sc >= beta) return sc; }
    }
    return alpha;
}

static int has_non_pawn_material(void) {
    for (int s = 21; s < 99; s++) {
        int pc = board[s];
        if (pc != OFF && pc != EMPTY && COLOR(pc) == side && TYPE(pc) >= KNIGHT && TYPE(pc) <= QUEEN) return 1;
    }
    return 0;
}

static int search(int alpha, int beta, int depth, int ply, int allow_null) {
    pv_len[ply] = ply;
    if (ply && (is_repetition() || half >= 100)) return 0;
    int check = in_check();
    if (check) depth++;
    if (depth <= 0) return quiesce(alpha, beta, ply);
    nodes++; check_time();
    if (stop_search) return 0;
    if (ply >= MAX_PLY - 1) return evaluate();
    int pv_node = beta - alpha > 1;

    /* transposition table probe */
    TTEntry *e = &tt[hash & ((1 << TT_BITS) - 1)];
    Move tt_move = 0;
    if (e->key == hash) {
        tt_move = e->move;
        if (e->depth >= depth && ply && !pv_node) {
            int s = e->score;
            if (s > MATE - MAX_PLY) s -= ply; else if (s < -MATE + MAX_PLY) s += ply;
            if (e->flag == TT_EXACT) return s;
            if (e->flag == TT_LOWER && s >= beta) return s;
            if (e->flag == TT_UPPER && s <= alpha) return s;
        }
    }

    /* null-move pruning */
    if (allow_null && !check && !pv_node && depth >= 3 && has_non_pawn_material() && evaluate() >= beta) {
        make_null();
        int R = 2 + depth / 4;
        int sc = -search(-beta, -beta + 1, depth - 1 - R, ply + 1, 0);
        unmake_null();
        if (stop_search) return 0;
        if (sc >= beta && !IS_MATE(sc)) return beta;
    }

    MoveList l; gen_moves(&l, 0);
    score_moves(&l, tt_move, ply);
    int legal = 0, best = -INF, old_alpha = alpha;
    Move best_move = 0;
    for (int i = 0; i < l.n; i++) {
        Move m = pick_next(&l, i);
        int quiet = board[M_TO(m)] == EMPTY && M_FLAG(m) != F_EP && !M_PROMO(m);
        if (!make(m)) continue;
        legal++;
        int sc;
        if (legal == 1) sc = -search(-beta, -alpha, depth - 1, ply + 1, 1);
        else {
            /* late move reductions for quiet moves searched late */
            int red = 0;
            if (depth >= 3 && legal > 4 && quiet && !check && !in_check()) red = 1 + (legal > 12) + (depth > 6);
            sc = -search(-alpha - 1, -alpha, depth - 1 - red, ply + 1, 1);
            if (sc > alpha && red) sc = -search(-alpha - 1, -alpha, depth - 1, ply + 1, 1);
            if (sc > alpha && sc < beta) sc = -search(-beta, -alpha, depth - 1, ply + 1, 1);
        }
        unmake();
        if (stop_search) return 0;
        if (sc > best) {
            best = sc; best_move = m;
            if (sc > alpha) {
                alpha = sc;
                pv_table[ply][ply] = m;
                for (int j = ply + 1; j < pv_len[ply + 1]; j++) pv_table[ply][j] = pv_table[ply + 1][j];
                pv_len[ply] = pv_len[ply + 1];
                if (sc >= beta) {
                    if (quiet) {
                        if (killers[ply][0] != m) { killers[ply][1] = killers[ply][0]; killers[ply][0] = m; }
                        history[board[M_FROM(m)]][M_TO(m)] += depth * depth;
                        if (history[board[M_FROM(m)]][M_TO(m)] > 800000)
                            for (int a = 0; a < 16; a++) for (int b = 0; b < 120; b++) history[a][b] /= 2;
                    }
                    break;
                }
            }
        }
    }
    if (!legal) return check ? -MATE + ply : 0;

    int flag = best >= beta ? TT_LOWER : (alpha > old_alpha ? TT_EXACT : TT_UPPER);
    int store = best;
    if (store > MATE - MAX_PLY) store += ply; else if (store < -MATE + MAX_PLY) store -= ply;
    e->key = hash; e->move = best_move; e->score = (int16_t)store; e->depth = (int8_t)depth; e->flag = (uint8_t)flag;
    return best;
}

static int verbose_info = 1;

/* iterative deepening; returns best move */
static Move think(int max_depth, long long ms, int *out_score) {
    memset(killers, 0, sizeof killers);
    for (int a = 0; a < 16; a++) for (int b = 0; b < 120; b++) history[a][b] /= 8;
    nodes = 0; stop_search = 0; t_start = now_ms(); t_limit = ms;
    Move best = 0; int best_score = 0;
    {   /* fallback: first legal move */
        MoveList l; gen_moves(&l, 0);
        for (int i = 0; i < l.n; i++) if (make(l.m[i])) { unmake(); best = l.m[i]; break; }
    }
    for (int d = 1; d <= max_depth; d++) {
        int sc = search(-INF, INF, d, 0, 0);
        if (stop_search) break;
        best_score = sc;
        if (pv_len[0] > 0) best = pv_table[0][0];
        long long el = now_ms() - t_start;
        if (verbose_info) {
            printf("info depth %d score ", d);
            if (IS_MATE(sc)) printf("mate %d", sc > 0 ? (MATE - sc + 1) / 2 : -(MATE + sc) / 2);
            else printf("cp %d", sc);
            printf(" nodes %llu time %lld nps %llu pv", (unsigned long long)nodes, el,
                   (unsigned long long)(el ? nodes * 1000 / el : nodes));
            for (int i = 0; i < pv_len[0]; i++) printf(" %s", move_str(pv_table[0][i]));
            printf("\n"); fflush(stdout);
        }
        if (IS_MATE(sc) && d > 2 && MATE - abs(sc) < d) break;
        /* don't start an iteration we likely can't finish */
        if (t_limit > 0 && el > t_limit / 2) break;
    }
    if (out_score) *out_score = best_score;
    return best;
}

/* ------------------------------------------------------------ display */
static void print_board(void) {
    printf("\n");
    for (int r = 7; r >= 0; r--) {
        printf("  %d  ", r + 1);
        for (int f = 0; f < 8; f++) {
            int pc = board[SQ(f, r)];
            printf("%c ", pc == EMPTY ? (((f + r) & 1) ? '.' : ':') : PIECE_CH[pc]);
        }
        printf("\n");
    }
    printf("\n     a b c d e f g h     %s to move\n\n", side == WHITE ? "White" : "Black");
}

static int game_over(const char **why) {
    MoveList l; gen_moves(&l, 0); int legal = 0;
    for (int i = 0; i < l.n && !legal; i++) if (make(l.m[i])) { legal = 1; unmake(); }
    if (!legal) { *why = in_check() ? (side == WHITE ? "0-1 (checkmate)" : "1-0 (checkmate)") : "1/2-1/2 (stalemate)"; return 1; }
    if (half >= 100) { *why = "1/2-1/2 (fifty-move rule)"; return 1; }
    int reps = 0;
    for (int i = hply - 2; i >= 0 && i >= hply - half; i -= 2) if (hist_hash[i] == hash) reps++;
    if (reps >= 2) { *why = "1/2-1/2 (threefold repetition)"; return 1; }
    /* bare kings / insufficient material */
    int minor = 0, other = 0;
    for (int s = 21; s < 99; s++) {
        int t = TYPE(board[s]);
        if (board[s] == OFF || board[s] == EMPTY || t == KING) continue;
        if (t == KNIGHT || t == BISHOP) minor++; else other++;
    }
    if (!other && minor <= 1) { *why = "1/2-1/2 (insufficient material)"; return 1; }
    return 0;
}

/* ------------------------------------------------------------- commands */
static void tt_clear(void) { memset(tt, 0, sizeof(TTEntry) << TT_BITS); memset(history, 0, sizeof history); }

static int run_perft_suite(void) {
    static const struct { const char *fen; int depth; uint64_t expect; const char *name; } T[] = {
        { START_FEN, 5, 4865609ULL, "start position" },
        { "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 4, 4085603ULL, "kiwipete" },
        { "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 6, 11030083ULL, "rook endgame / ep pins" },
        { "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 5, 15833292ULL, "promotions + castling" },
        { "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 4, 2103487ULL, "underpromotion" },
        { "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", 4, 3894594ULL, "middlegame" },
    };
    int ok = 1; uint64_t total = 0; long long t0 = now_ms();
    for (size_t i = 0; i < sizeof T / sizeof T[0]; i++) {
        set_fen(T[i].fen);
        long long a = now_ms();
        uint64_t n = perft(T[i].depth);
        long long b = now_ms();
        total += n;
        printf("%-24s depth %d  %12llu  %s  (%lld ms)\n", T[i].name, T[i].depth,
               (unsigned long long)n, n == T[i].expect ? "OK  " : "FAIL", b - a);
        if (n != T[i].expect) ok = 0;
    }
    long long el = now_ms() - t0;
    printf("\n%llu nodes in %lld ms (%.1f Mnps) - %s\n", (unsigned long long)total, el,
           el ? total / 1000.0 / el : 0.0, ok ? "all perft tests passed" : "PERFT FAILURES");
    return ok ? 0 : 1;
}

static void uci_loop(void) {
    char line[8192];
    set_fen(START_FEN);
    setvbuf(stdout, NULL, _IONBF, 0);
    while (fgets(line, sizeof line, stdin)) {
        if (!strncmp(line, "uci", 3) && (line[3] == '\n' || line[3] == '\r' || !line[3])) {
            printf("id name Kestrel 1.0\nid author zediedsnow\nuciok\n");
        } else if (!strncmp(line, "isready", 7)) printf("readyok\n");
        else if (!strncmp(line, "ucinewgame", 10)) { tt_clear(); set_fen(START_FEN); }
        else if (!strncmp(line, "position", 8)) {
            char *p = line + 9;
            if (!strncmp(p, "startpos", 8)) set_fen(START_FEN);
            else if (!strncmp(p, "fen", 3)) set_fen(p + 4);
            char *mv = strstr(line, "moves");
            if (mv) {
                char *tok = strtok(mv + 5, " \n\r");
                while (tok) { Move m = parse_move(tok); if (!m || !make(m)) break; tok = strtok(NULL, " \n\r"); }
            }
        } else if (!strncmp(line, "go", 2)) {
            int depth = 64; long long ms = 0, wt = -1, bt = -1, wi = 0, bi = 0, mtg = 30;
            char *p;
            if ((p = strstr(line, "depth"))) depth = atoi(p + 6);
            if ((p = strstr(line, "movetime"))) ms = atoll(p + 9);
            if ((p = strstr(line, "wtime"))) wt = atoll(p + 6);
            if ((p = strstr(line, "btime"))) bt = atoll(p + 6);
            if ((p = strstr(line, "winc"))) wi = atoll(p + 5);
            if ((p = strstr(line, "binc"))) bi = atoll(p + 5);
            if ((p = strstr(line, "movestogo"))) mtg = atoll(p + 10);
            long long left = side == WHITE ? wt : bt, inc = side == WHITE ? wi : bi;
            if (!ms && left >= 0) { ms = left / (mtg + 2) + inc * 3 / 4; if (ms > left - 50) ms = left > 100 ? left - 50 : left / 2; }
            if (ms <= 0 && depth == 64) ms = (strstr(line, "infinite") ? 0 : 5000);
            Move m = think(depth, ms, NULL);
            printf("bestmove %s\n", move_str(m));
        } else if (!strncmp(line, "d", 1) && (line[1] == '\n' || line[1] == '\r')) print_board();
        else if (!strncmp(line, "quit", 4)) break;
    }
}

static void play_human(int human_side, long long ms) {
    char line[256];
    set_fen(START_FEN);
    verbose_info = 0;
    printf("Kestrel chess. You play %s. Enter moves like e2e4, e7e8q; 'quit' to stop.\n",
           human_side == WHITE ? "White" : "Black");
    for (;;) {
        print_board();
        const char *why;
        if (game_over(&why)) { printf("Game over: %s\n", why); break; }
        if (side == human_side) {
            printf("your move> "); fflush(stdout);
            if (!fgets(line, sizeof line, stdin) || !strncmp(line, "quit", 4)) break;
            Move m = parse_move(line);
            if (!m) { printf("illegal move\n"); continue; }
            printf("you play %s\n", san(m));
            make(m);
        } else {
            int sc; Move m = think(64, ms, &sc);
            printf("Kestrel plays %s  (eval %+.2f, %llu nodes)\n", san(m), sc / 100.0, (unsigned long long)nodes);
            make(m);
        }
    }
}

static void selfplay(long long ms, int max_moves) {
    set_fen(START_FEN);
    verbose_info = 0;
    const char *why = "*";
    printf("[White \"Kestrel\"]\n[Black \"Kestrel\"]\n[TimeControl \"%lldms/move\"]\n\n", ms);
    int col = 0;
    for (int ply = 0; ply < max_moves * 2; ply++) {
        if (game_over(&why)) break;
        why = "*";
        int sc; Move m = think(64, ms, &sc);
        char tok[32];
        if (side == WHITE) snprintf(tok, sizeof tok, "%d. %s", ply / 2 + 1, san(m));
        else snprintf(tok, sizeof tok, "%s", san(m));
        col += (int)strlen(tok) + 1;
        if (col > 72) { printf("\n"); col = (int)strlen(tok) + 1; }
        printf("%s ", tok); fflush(stdout);
        make(m);
    }
    printf("\n\nResult: %s\n", why);
    print_board();
}

static void solve(const char *fen, int depth) {
    if (!set_fen(fen)) { printf("bad FEN\n"); return; }
    print_board();
    int sc; Move m = think(depth, 0, &sc);
    printf("\nbest move: %s  ", san(m));
    if (IS_MATE(sc)) printf("(%s in %d)\n", sc > 0 ? "mate" : "mated", sc > 0 ? (MATE - sc + 1) / 2 : (MATE + sc) / 2);
    else printf("(eval %+.2f)\n", sc / 100.0);
}

static void bench(void) {
    static const char *fens[] = {
        START_FEN,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3",
        "8/8/3k4/8/2PK4/8/8/8 w - - 0 1",
    };
    uint64_t total = 0; long long t0 = now_ms();
    verbose_info = 0;
    for (int i = 0; i < 4; i++) {
        tt_clear(); set_fen(fens[i]);
        int sc; Move m = think(9, 0, &sc);
        printf("%-72s depth 9  %-6s %+6d cp  %9llu nodes\n", fens[i], move_str(m), sc, (unsigned long long)nodes);
        total += nodes;
    }
    long long el = now_ms() - t0;
    printf("\nbench: %llu nodes in %lld ms (%llu nps)\n", (unsigned long long)total, el,
           (unsigned long long)(el ? total * 1000 / el : 0));
}

int main(int argc, char **argv) {
    init_tables();
    tt = calloc((size_t)1 << TT_BITS, sizeof(TTEntry));
    if (!tt) return 1;
    const char *cmd = argc > 1 ? argv[1] : "uci";
    if (!strcmp(cmd, "uci")) uci_loop();
    else if (!strcmp(cmd, "perft")) {
        if (argc > 2) {
            int d = atoi(argv[2]);
            set_fen(argc > 3 ? argv[3] : START_FEN);
            MoveList l; gen_moves(&l, 0); uint64_t total = 0;
            for (int i = 0; i < l.n; i++) {
                if (!make(l.m[i])) continue;
                uint64_t n = perft(d - 1); unmake();
                printf("%s: %llu\n", move_str(l.m[i]), (unsigned long long)n); total += n;
            }
            printf("\ntotal: %llu\n", (unsigned long long)total);
        } else return run_perft_suite();
    }
    else if (!strcmp(cmd, "play")) play_human(argc > 2 && argv[2][0] == 'b' ? BLACK : WHITE, argc > 3 ? atoll(argv[3]) : 2000);
    else if (!strcmp(cmd, "selfplay")) selfplay(argc > 2 ? atoll(argv[2]) : 300, argc > 3 ? atoi(argv[3]) : 120);
    else if (!strcmp(cmd, "solve") && argc > 2) solve(argv[2], argc > 3 ? atoi(argv[3]) : 10);
    else if (!strcmp(cmd, "bench")) bench();
    else {
        printf("usage: %s [uci | perft [depth [fen]] | play [w|b] [ms] | selfplay [ms] [moves] | solve <fen> [depth] | bench]\n", argv[0]);
        return 1;
    }
    return 0;
}
