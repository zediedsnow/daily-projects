# ---------------------------------------------------------------------------
# Vectorised reverse-mode automatic differentiation for base R.
#
# A value that depends on the parameters is an "adv" object: a node on a
# global tape holding a whole numeric vector or matrix.  Arithmetic, Math,
# Summary and %*% are hooked through R's S3 group generics, so ordinary R
# code such as  sum(dnorm-style formulas)  or  X %*% beta  records itself on
# the tape when fed an adv.  One tape node per *vector* operation keeps the
# interpreter overhead independent of the data size.
# ---------------------------------------------------------------------------

# Each node is an immutable list(id, v, p = parent nodes, bw = backward fn).
# Ids increase monotonically, so a reverse sweep over ids is a valid
# topological order; no global tape arrays need to be mutated.
.ad <- new.env(parent = emptyenv())
.ad$n <- 0L

is_adv <- function(x) inherits(x, "adv")
val    <- function(x) if (inherits(x, "adv")) .subset2(x, "v") else x
adv_id <- function(x) .subset2(x, "id")

mk_node <- function(value, parents, bw) {
  n <- .ad$n + 1L
  .ad$n <- n
  x <- list(id = n, v = value, p = parents, bw = bw)
  oldClass(x) <- "adv"
  x
}

adv_leaf <- function(x) mk_node(x, NULL, NULL)

# Undo R's recycling: fold a gradient of the broadcast result back onto the
# shape of the operand that was recycled.
unbroadcast <- function(g, like) {
  n <- length(like)
  d <- dim(like)
  if (length(g) == n) {
    if (is.null(d)) { if (is.null(dim(g))) return(g); return(as.vector(g)) }
    return(array(g, d))
  }
  g <- if (n == 1L) sum(g) else as.vector(rowsum(as.vector(g), ((seq_along(g) - 1L) %% n) + 1L))
  if (is.null(d)) g else array(g, d)
}

# Record an operation: `args` are its inputs (adv or plain), `dfs` a list of
# functions g -> d(out)/d(arg)^T g, one per argument.
record <- function(out, args, dfs) {
  keep <- which(vapply(args, is_adv, logical(1)))
  if (!length(keep)) return(out)
  parents <- args[keep]
  if (length(keep) == 1L) {
    f <- dfs[[keep]]; like <- val(parents[[1L]])
    return(mk_node(out, parents, function(g) list(unbroadcast(f(g), like))))
  }
  likes <- lapply(parents, val)
  fns   <- dfs[keep]
  mk_node(out, parents, function(g)
    lapply(seq_along(fns), function(k) unbroadcast(fns[[k]](g), likes[[k]])))
}

Ops.adv <- function(e1, e2) {
  if (nargs() == 1L) {
    a <- val(e1)
    return(switch(.Generic,
      "-" = record(-a, list(e1), list(function(g) -g)),
      "+" = e1,
      stop("unsupported unary op ", .Generic)))
  }
  a <- val(e1); b <- val(e2)
  if (.Generic %in% c("==", "!=", "<", ">", "<=", ">=", "&", "|"))
    return(get(.Generic)(a, b))
  out <- switch(.Generic,
    "+" = a + b, "-" = a - b, "*" = a * b, "/" = a / b, "^" = a ^ b,
    stop("unsupported op ", .Generic))
  da <- switch(.Generic,
    "+" = function(g) g,       "-" = function(g) g,
    "*" = function(g) g * b,   "/" = function(g) g / b,
    "^" = function(g) g * b * a ^ (b - 1))
  db <- switch(.Generic,
    "+" = function(g) g,       "-" = function(g) -g,
    "*" = function(g) g * a,   "/" = function(g) -g * a / b ^ 2,
    "^" = function(g) g * out * log(a))
  ia <- is_adv(e1); ib <- is_adv(e2)
  if (ia && ib) mk_node(out, list(e1, e2), function(g) list(unbroadcast(da(g), a), unbroadcast(db(g), b)))
  else if (ia)  mk_node(out, list(e1), function(g) list(unbroadcast(da(g), a)))
  else          mk_node(out, list(e2), function(g) list(unbroadcast(db(g), b)))
}

Math.adv <- function(x, ...) {
  a <- val(x)
  out <- get(.Generic)(a, ...)
  d <- switch(.Generic,
    exp    = function(g) g * out,
    log    = { if (length(list(...))) stop("log(x, base) not supported"); function(g) g / a },
    sqrt   = function(g) g / (2 * out),
    abs    = function(g) g * sign(a),
    log1p  = function(g) g / (1 + a),
    expm1  = function(g) g * (out + 1),
    sin    = function(g) g * cos(a),
    cos    = function(g) -g * sin(a),
    tanh   = function(g) g * (1 - out ^ 2),
    atan   = function(g) g / (1 + a ^ 2),
    lgamma = function(g) g * digamma(a),
    digamma = function(g) g * trigamma(a),
    cumsum = function(g) rev(cumsum(rev(g))),
    stop("Math function ", .Generic, " not differentiable here"))
  record(out, list(x), list(d))
}

Summary.adv <- function(..., na.rm = FALSE) {
  args <- list(...)
  if (.Generic != "sum") {
    if (.Generic %in% c("max", "min") && length(args) == 1L) {
      a <- val(args[[1]])
      k <- if (.Generic == "max") which.max(a) else which.min(a)
      return(record(a[k], args, list(function(g) { z <- numeric(length(a)); z[k] <- g; z })))
    }
    stop("Summary function ", .Generic, " not supported")
  }
  out <- sum(vapply(args, function(z) sum(val(z)), numeric(1)))
  record(out, args, lapply(args, function(z) { n <- length(val(z)); function(g) rep(g, n) }))
}

# %*% via R >= 4.3's matrixOps group generic.  Vectors are read the way R
# reads them: a column on the right, a row on the left.
matrixOps.adv <- function(x, y) {
  if (.Generic != "%*%") stop("matrix op ", .Generic, " not supported")
  a <- val(x); b <- val(y)
  A <- if (is.null(dim(a))) matrix(a, nrow = 1) else a
  B <- if (is.null(dim(b))) matrix(b, ncol = 1) else b
  if (is.null(dim(a)) && nrow(B) != length(a)) A <- matrix(a, ncol = 1)
  out <- A %*% B
  record(out, list(x, y), list(
    function(g) matrix(g, nrow(out)) %*% t(B),
    function(g) t(A) %*% matrix(g, nrow(out))))
}

`[.adv` <- function(x, ...) {
  a <- val(x)
  idx <- (if (is.null(dim(a))) seq_along(a) else array(seq_along(a), dim(a)))[...]
  n <- length(a)
  if (length(idx) == 1L)
    return(record(a[...], list(x), list(function(g) { z <- numeric(n); z[idx] <- g; z })))
  record(a[...], list(x), list(function(g) {
    s <- rowsum(as.vector(g), as.vector(idx))
    z <- numeric(n); z[as.integer(rownames(s))] <- s[, 1]; z
  }))
}

length.adv <- function(x) length(.subset2(x, "v"))
print.adv  <- function(x, ...) { cat("<adv node", adv_id(x), ">\n"); print(val(x)); invisible(x) }

# Concatenate adv and plain vectors.
ad_c <- function(...) {
  args <- list(...)
  vals <- lapply(args, val)
  lens <- lengths(vals)
  ends <- cumsum(lens); starts <- ends - lens + 1L
  record(unlist(vals, use.names = FALSE), args,
         lapply(seq_along(args), function(k) function(g) g[starts[k]:ends[k]]))
}

# rep() for adv (rep(x, times) and rep(x, each=)).
ad_rep <- function(x, times = 1L, each = 1L) {
  a <- val(x)
  src <- rep(seq_along(a), times = times, each = each)
  record(a[src], list(x), list(function(g) {
    z <- numeric(length(a)); s <- rowsum(as.vector(g), src); z[as.integer(rownames(s))] <- s[, 1]; z }))
}

# --- numerically careful primitives ----------------------------------------
softplus <- function(x) {                     # log(1 + exp(x))
  a <- val(x)
  out <- pmax(a, 0) + log1p(exp(-abs(a)))
  record(out, list(x), list(function(g) g * plogis(a)))
}
inv_logit <- function(x) {
  a <- val(x); out <- plogis(a)
  record(out, list(x), list(function(g) g * out * (1 - out)))
}
log_sum_exp <- function(x) {
  a <- val(x); m <- max(a)
  out <- m + log(sum(exp(a - m)))
  record(out, list(x), list(function(g) g * exp(a - out)))
}

# --- the user-facing entry point -------------------------------------------
# Value and gradient of scalar f at numeric vector x.
ad_grad <- function(f, x) {
  .ad$n <- 0L
  xv <- adv_leaf(x)
  y <- f(xv)
  if (!is_adv(y)) return(list(value = as.numeric(y), grad = numeric(length(x))))
  if (length(val(y)) != 1L) stop("f must return a scalar")
  n <- adv_id(y)
  nodes <- vector("list", n); grads <- vector("list", n)
  nodes[[n]] <- y; grads[[n]] <- 1
  for (i in n:1L) {
    nd <- nodes[[i]]
    if (is.null(nd)) next
    fb <- .subset2(nd, "bw")
    if (is.null(fb)) next
    pg <- fb(grads[[i]])
    ps <- .subset2(nd, "p")
    for (k in seq_along(ps)) {
      pk <- ps[[k]]; j <- .subset2(pk, "id")
      if (is.null(nodes[[j]])) { nodes[[j]] <- pk; grads[[j]] <- pg[[k]] }
      else grads[[j]] <- grads[[j]] + pg[[k]]
    }
  }
  g1 <- grads[[1L]]
  list(value = as.numeric(val(y)), grad = if (is.null(g1)) numeric(length(x)) else as.vector(g1))
}

# Drop dim attributes (as.vector() is not S3-generic, so adv needs its own).
ad_vec <- function(x) record(as.vector(val(x)), list(x), list(function(g) g))
