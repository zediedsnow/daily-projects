# Differential test: nutmeg's R-hat / bulk-ESS / tail-ESS against the
# reference implementation in the `posterior` package (Stan team), on
# random sets of autocorrelated, shifted and heavy-tailed chains.
source("nutmeg.R")
if (!requireNamespace("posterior", quietly = TRUE)) { cat("posterior not installed; skipping\n"); quit() }
set.seed(7)
N <- as.integer(Sys.getenv("DIAG_CASES", "1000"))
ar1 <- function(n, phi) as.vector(arima.sim(list(ar = phi), n, sd = sqrt(1 - phi^2)))
worst <- c(rhat = 0, ess_bulk = 0, ess_tail = 0)
for (t in seq_len(N)) {
  n <- sample(c(20, 50, 100, 400, 1000), 1); m <- sample(1:6, 1)
  phi <- runif(1, -0.5, 0.97)
  x <- sapply(seq_len(m), function(j) ar1(n, phi) + rnorm(1, 0, runif(1, 0, 1)))
  x <- matrix(x, n, m)
  if (runif(1) < 0.3) x <- x ^ 3                     # heavy tails
  if (runif(1) < 0.1) x <- round(x, 1)               # ties
  ref <- suppressWarnings(c(posterior::rhat(x), posterior::ess_bulk(x), posterior::ess_tail(x)))
  got <- c(rhat(x), ess_bulk(x), ess_tail(x))
  rel <- abs(got - ref) / pmax(abs(ref), 1e-8)
  rel[is.na(ref) & is.na(got)] <- 0
  worst <- pmax(worst, rel)
}
cat(sprintf("Diagnostics vs posterior %s on %d random chain sets: max relative difference R-hat %.1e, bulk-ESS %.1e, tail-ESS %.1e\n",
            packageVersion("posterior"), N, worst[1], worst[2], worst[3]))
if (any(worst > 1e-8)) quit(status = 1)
