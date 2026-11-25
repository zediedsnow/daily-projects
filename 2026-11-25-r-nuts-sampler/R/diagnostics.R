# ---------------------------------------------------------------------------
# Convergence diagnostics from Vehtari, Gelman, Simpson, Carpenter & Bürkner
# (2021): rank-normalised split-R-hat, bulk-ESS and tail-ESS, with Geyer's
# initial monotone sequence on FFT autocovariances.
# `x` is always an iterations x chains matrix.
# ---------------------------------------------------------------------------

autocov <- function(x) {
  n <- length(x)
  m <- 2L ^ ceiling(log2(2L * n))
  f <- fft(c(x - mean(x), numeric(m - n)))
  Re(fft(Mod(f) ^ 2, inverse = TRUE))[seq_len(n)] / m / n
}

split_chains <- function(x) {
  x <- as.matrix(x); n <- nrow(x); h <- n %/% 2L
  cbind(x[seq_len(h), , drop = FALSE], x[(n - h + 1L):n, , drop = FALSE])
}

z_scale <- function(x) {
  r <- rank(x, ties.method = "average")
  array(qnorm((r - 3 / 8) / (length(x) + 1 / 4)), dim(x))
}

rhat_basic <- function(x, split = TRUE) {
  x <- if (split) split_chains(x) else as.matrix(x); n <- nrow(x)
  if (any(!is.finite(x))) return(NA_real_)
  if (var(as.vector(x)) == 0) return(NA_real_)
  W <- mean(apply(x, 2, var)); B <- n * var(colMeans(x))
  sqrt(((n - 1) / n * W + B / n) / W)
}

ess_basic <- function(x, split = TRUE) {
  x <- if (split) split_chains(x) else as.matrix(x)
  n <- nrow(x); m <- ncol(x)
  if (n < 3L || any(!is.finite(x)) || var(as.vector(x)) == 0) return(NA_real_)
  acov <- vapply(seq_len(m), function(j) autocov(x[, j]), numeric(n))
  acov <- matrix(acov, n, m)
  chain_mean <- colMeans(x)
  mean_var <- mean(acov[1, ]) * n / (n - 1)
  var_plus <- mean_var * (n - 1) / n
  if (m > 1L) var_plus <- var_plus + var(chain_mean)
  rho <- numeric(n)
  t <- 0L
  even <- 1; rho[1] <- even
  odd <- 1 - (mean_var - mean(acov[2, ])) / var_plus; rho[2] <- odd
  while (t < n - 5L && !is.nan(even + odd) && even + odd > 0) {
    t <- t + 2L
    even <- 1 - (mean_var - mean(acov[t + 1L, ])) / var_plus
    odd  <- 1 - (mean_var - mean(acov[t + 2L, ])) / var_plus
    if (even + odd >= 0) { rho[t + 1L] <- even; rho[t + 2L] <- odd }
  }
  max_t <- t
  if (even > 0) rho[max_t + 1L] <- even
  t <- 0L
  while (t <= max_t - 4L) {                       # make the sequence monotone
    t <- t + 2L
    if (rho[t + 1L] + rho[t + 2L] > rho[t - 1L] + rho[t]) {
      rho[t + 1L] <- (rho[t - 1L] + rho[t]) / 2; rho[t + 2L] <- rho[t + 1L]
    }
  }
  S <- m * n
  tau <- -1 + 2 * sum(rho[seq_len(max_t)]) + rho[max_t + 1L]
  tau <- max(tau, 1 / log10(S))
  S / tau
}

rhat <- function(x) {
  x <- as.matrix(x)
  sx <- split_chains(x)
  max(rhat_basic(z_scale(sx), split = FALSE),
      rhat_basic(z_scale(abs(sx - median(sx))), split = FALSE))
}
ess_bulk <- function(x) ess_basic(z_scale(split_chains(as.matrix(x))), split = FALSE)
ess_tail <- function(x) {
  x <- as.matrix(x)
  q <- quantile(x, c(0.05, 0.95), names = FALSE)
  min(ess_basic((x <= q[1]) + 0), ess_basic((x <= q[2]) + 0))
}
mcse_mean <- function(x) sd(as.vector(x)) / sqrt(ess_basic(x))

summary.nm_fit <- function(object, ...) {
  dr <- object$draws
  rows <- lapply(seq_len(dim(dr)[2]), function(j) {
    x <- matrix(dr[, j, ], dim(dr)[1])
    v <- as.vector(x)
    data.frame(param = dimnames(dr)[[2]][j], mean = mean(v), sd = sd(v),
               q5 = quantile(v, 0.05, names = FALSE), q50 = median(v),
               q95 = quantile(v, 0.95, names = FALSE), mcse = mcse_mean(x),
               rhat = rhat(x), ess_bulk = ess_bulk(x), ess_tail = ess_tail(x))
  })
  do.call(rbind, rows)
}

print.nm_fit <- function(x, digits = 3, ...) {
  s <- summary(x)
  st <- do.call(rbind, lapply(x$chains, `[[`, "stats"))
  el <- sum(vapply(x$chains, `[[`, numeric(1), "elapsed"))
  cat(sprintf("nutmeg NUTS fit of '%s': %d chains x %d draws, %d params\n",
              x$model$name, length(x$chains), dim(x$draws)[1], dim(x$draws)[2]))
  cat(sprintf("step sizes %s | mean tree depth %.2f | %d leapfrogs | divergences %d | %.1fs sampling CPU\n",
              paste(signif(vapply(x$chains, `[[`, numeric(1), "step_size"), 3), collapse = ", "),
              mean(st$depth), sum(st$n_leapfrog), sum(st$divergent), el))
  s[-1] <- lapply(s[-1], function(c) signif(c, digits))
  s$ess_bulk <- round(s$ess_bulk); s$ess_tail <- round(s$ess_tail)
  print(s, row.names = FALSE)
  invisible(x)
}

# E-BFMI per chain (energy Bayesian fraction of missing information).
ebfmi <- function(fit) vapply(fit$chains, function(ch) {
  e <- ch$stats$energy; sum(diff(e) ^ 2) / sum((e - mean(e)) ^ 2) }, numeric(1))
