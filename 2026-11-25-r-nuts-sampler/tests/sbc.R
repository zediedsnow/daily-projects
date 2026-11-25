# Simulation-based calibration (Talts et al. 2018): draw parameters from the
# prior, simulate data, fit, and record the rank of the true value among
# thinned posterior draws.  A correct sampler gives uniform ranks; bias,
# over/under-dispersion or a broken Jacobian all show up as non-uniformity.
source("nutmeg.R")
REPS <- as.integer(Sys.getenv("SBC_REPS", "200"))
L <- 99L; thin <- 6L; bins <- 20L
one <- function(r) {
  set.seed(5000 + r)
  mu <- rnorm(1); sigma <- exp(rnorm(1, 0, 0.5)); w <- rbeta(1, 2, 2)
  y <- rnorm(8, mu, sigma); k <- rbinom(1, 12, w)
  m <- nm_model(list(mu = real(), sigma = positive(), w = bounded(0, 1)), function(p, d)
    normal_lpdf(p$mu, 0, 1) + lognormal_lpdf(p$sigma, 0, 0.5) + normal_lpdf(d$y, p$mu, p$sigma) +
    beta_lpdf(p$w, 2, 2) + d$k * log(p$w) + (12 - d$k) * log1p(-p$w),
    data = list(y = y, k = k), name = "sbc")
  ch <- nuts_chain(m, iter = L * thin, warmup = 300L, seed = 9000 + r)
  dr <- ch$draws[seq(thin, L * thin, by = thin), , drop = FALSE]
  c(mu = sum(dr[, "mu"] < mu), sigma = sum(dr[, "sigma"] < sigma), w = sum(dr[, "w"] < w))
}
t0 <- Sys.time()
ranks <- do.call(rbind, parallel::mclapply(seq_len(REPS), one, mc.cores = 2L))
saveRDS(ranks, "out/sbc_ranks.rds")
cat(sprintf("SBC: %d replications x 3 parameters (%.0fs)\n", REPS, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
ok <- TRUE
for (p in colnames(ranks)) {
  counts <- tabulate(ranks[, p] %/% ((L + 1L) / bins) + 1L, bins)
  test <- chisq.test(counts)
  cat(sprintf("  %-6s rank histogram %s  chi2(%d) = %5.1f, p = %.3f\n", p,
              paste(counts, collapse = " "), bins - 1L, test$statistic, test$p.value))
  if (test$p.value < 0.001) ok <- FALSE
}
png("out/sbc.png", width = 1200, height = 380, res = 110, type = "cairo")
par(mfrow = c(1, 3), mar = c(4, 4, 3, 1), bg = "#fbfaf7")
for (p in colnames(ranks)) {
  hist(ranks[, p], breaks = seq(0, L + 1, length.out = bins + 1), col = "#9db7d1", border = "white",
       main = sprintf("SBC ranks: %s", p), xlab = "rank of true value among 99 draws", las = 1)
  ci <- qbinom(c(0.005, 0.995), REPS, 1 / bins)
  rect(-5, ci[1], L + 6, ci[2], col = adjustcolor("grey50", 0.15), border = NA)
  abline(h = REPS / bins, lty = 2)
}
invisible(dev.off())
cat(if (ok) "SBC: ranks consistent with uniform for every parameter\n" else "SBC: FAIL\n")
if (!ok) quit(status = 1)
