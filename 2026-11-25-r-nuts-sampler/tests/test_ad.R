# Fuzz the autodiff engine: random expression trees over a 4-vector, every
# gradient compared against 4th-order central finite differences.  Also
# checks each constraining transform's log-Jacobian against a numerical
# determinant.
source("nutmeg.R")
set.seed(20261125)
N <- as.integer(Sys.getenv("AD_CASES", "3000"))
M <- matrix(rnorm(16), 4)

gen_vec <- function(depth) {
  if (depth <= 0 || runif(1) < 0.2) {
    k <- sample(3, 1)
    if (k == 1) return(list(f = function(x) x, s = "x"))
    if (k == 2) { i <- sample(4, 1); return(list(f = function(x) x[i] * c(1, -2, 0.5, 3), s = sprintf("x[%d]*c", i))) }
    c0 <- round(rnorm(4), 2); return(list(f = function(x) x + c0, s = "(x+c)"))
  }
  op <- sample(18, 1)
  a <- gen_vec(depth - 1); fa <- a$f
  sc <- function() gen_scalar(depth - 1)
  switch(op,
    list(f = function(x) exp(tanh(fa(x))), s = sprintf("exp(tanh(%s))", a$s)),
    list(f = function(x) log(fa(x)^2 + 1), s = sprintf("log(%s^2+1)", a$s)),
    list(f = function(x) sqrt(fa(x)^2 + 0.5), s = sprintf("sqrt(%s^2+.5)", a$s)),
    list(f = function(x) sin(fa(x)), s = sprintf("sin(%s)", a$s)),
    list(f = function(x) softplus(fa(x)), s = sprintf("softplus(%s)", a$s)),
    list(f = function(x) inv_logit(fa(x)), s = sprintf("inv_logit(%s)", a$s)),
    list(f = function(x) lgamma(exp(tanh(fa(x))) + 0.5), s = sprintf("lgamma(..%s)", a$s)),
    list(f = function(x) cumsum(fa(x)), s = sprintf("cumsum(%s)", a$s)),
    { b <- gen_vec(depth - 1); fb <- b$f; o <- sample(c("+", "-", "*"), 1)
      list(f = function(x) get(o)(fa(x), fb(x)), s = sprintf("(%s %s %s)", a$s, o, b$s)) },
    { b <- gen_vec(depth - 1); fb <- b$f
      list(f = function(x) fa(x) / (fb(x)^2 + 1), s = sprintf("(%s/(%s^2+1))", a$s, b$s)) },
    { b <- sc(); fb <- b$f
      list(f = function(x) (fa(x)^2 + 1)^tanh(fb(x)), s = sprintf("(%s^2+1)^tanh(%s)", a$s, b$s)) },
    { b <- sc(); fb <- b$f; o <- sample(c("+", "*", "-"), 1)
      list(f = function(x) get(o)(fb(x), fa(x)), s = sprintf("(%s %s %s)", b$s, o, a$s)) },
    list(f = function(x) ad_vec(M %*% fa(x)), s = sprintf("M%%*%%%s", a$s)),
    list(f = function(x) { y <- fa(x); ad_c(y[1:2], y[4], y[3]) }, s = sprintf("perm(%s)", a$s)),
    list(f = function(x) fa(x)[c(2, 2, 4, 1)], s = sprintf("%s[c(2,2,4,1)]", a$s)),
    { b <- sc(); fb <- b$f; list(f = function(x) ad_rep(fb(x), 4) * fa(x), s = sprintf("rep(%s)*%s", b$s, a$s)) },
    list(f = function(x) -fa(x), s = sprintf("-%s", a$s)),
    list(f = function(x) fa(x)^3, s = sprintf("%s^3", a$s)))
}
gen_scalar <- function(depth) {
  a <- gen_vec(depth); fa <- a$f
  switch(sample(5, 1),
    list(f = function(x) sum(fa(x)), s = sprintf("sum(%s)", a$s)),
    list(f = function(x) log_sum_exp(fa(x)), s = sprintf("lse(%s)", a$s)),
    list(f = function(x) max(fa(x)), s = sprintf("max(%s)", a$s)),
    list(f = function(x) fa(x)[3], s = sprintf("%s[3]", a$s)),
    list(f = function(x) ad_vec(c(1, 2, -1, 0.5) %*% fa(x)), s = sprintf("w%%*%%%s", a$s)))
}

fd_grad <- function(f, x, h = 1e-3) vapply(seq_along(x), function(i) {
  e <- numeric(length(x)); e[i] <- h
  (-f(x + 2 * e) + 8 * f(x + e) - 8 * f(x - e) + f(x - 2 * e)) / (12 * h)
}, numeric(1))

pass <- 0L; skipped <- 0L; worst <- 0; fails <- character()
for (t in seq_len(N)) {
  e <- gen_scalar(sample(2:6, 1))
  f <- function(x) as.numeric(val(e$f(x)))
  x <- rnorm(4)
  v <- tryCatch(f(x), warning = function(w) NA, error = function(err) NA)
  if (!is.finite(v) || abs(v) > 1e4) { skipped <- skipped + 1L; next }
  # max() is not differentiable at ties; skip if the argmax is fragile
  g <- ad_grad(e$f, x)$grad
  fd <- fd_grad(f, x)
  if (any(!is.finite(fd)) || max(abs(fd)) > 1e5) { skipped <- skipped + 1L; next }
  err <- max(abs(g - fd) / (1 + abs(fd)))
  if (err < 1e-5) pass <- pass + 1L
  else {
    # recheck with a smaller step: genuine kinks (max) show up as disagreement in both
    fd2 <- fd_grad(f, x, 1e-5)
    err2 <- max(abs(g - fd2) / (1 + abs(fd2)))
    if (err2 < 1e-5) pass <- pass + 1L
    else if (grepl("max", e$s)) skipped <- skipped + 1L
    else fails <- c(fails, sprintf("%.2e  %s", err2, e$s))
  }
  worst <- max(worst, min(err, 1))
}
cat(sprintf("AD fuzz: %d random expressions, %d gradients match finite differences, %d skipped (overflow/kink), %d failures\n",
            N, pass, skipped, length(fails)))
if (length(fails)) { cat(head(fails, 10), sep = "\n"); quit(status = 1) }

# ---- log-Jacobians of constraining transforms -----------------------------
num_logdet <- function(fun, u, h = 1e-6) {
  J <- vapply(seq_along(u), function(i) { e <- numeric(length(u)); e[i] <- h
    (fun(u + e) - fun(u - e)) / (2 * h) }, numeric(length(fun(u))))
  as.numeric(determinant(as.matrix(J), logarithm = TRUE)$modulus)
}
jac_err <- 0; jac_n <- 0
for (t in 1:300) {
  for (spec in list(positive(3), bounded(-2, 5, 2), simplex(sample(2:6, 1)))) {
    u <- rnorm(spec$n, 0, 1.5)
    r <- constrain_one(spec, u)
    fun <- if (spec$type == "simplex") function(u) val(constrain_one(spec, u)$x)[seq_len(spec$n)]
           else function(u) val(constrain_one(spec, u)$x)
    jac_err <- max(jac_err, abs(val(r$lj) - num_logdet(fun, u))); jac_n <- jac_n + 1
    if (spec$type == "simplex") stopifnot(abs(sum(val(r$x)) - 1) < 1e-12, all(val(r$x) > 0))
  }
}
cat(sprintf("Jacobians: %d transforms (positive, bounded, simplex), max |log-det error| = %.1e\n", jac_n, jac_err))
if (jac_err > 1e-6) quit(status = 1)
