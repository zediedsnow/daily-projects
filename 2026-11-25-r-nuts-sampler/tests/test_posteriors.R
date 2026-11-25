# Exactness tests: models whose posterior is known in closed form.  Every
# posterior mean must sit within 4.5 Monte-Carlo standard errors of the
# truth, and every posterior sd within 4.5 of its approximate standard error.
source("nutmeg.R")
set.seed(11)
options(nutmeg.cores = 2L, width = 160)
results <- list(); failed <- FALSE

check <- function(name, fit, mean_true, sd_true) {
  dr <- fit$draws
  P <- dim(dr)[2]
  zm <- zs <- rh <- es <- numeric(P)
  for (j in seq_len(P)) {
    x <- matrix(dr[, j, ], dim(dr)[1]); v <- as.vector(x)
    zm[j] <- (mean(v) - mean_true[j]) / mcse_mean(x)
    ess <- ess_basic((v - mean(v))^2 |> matrix(nrow(x)))
    # sd of the sd estimator ~ sd * sqrt((kurtosis - 1) / (4 ESS)); kurtosis from draws
    k <- mean((v - mean(v))^4) / var(v)^2
    zs[j] <- (sd(v) - sd_true[j]) / (sd_true[j] * sqrt((k - 1) / (4 * ess)))
    rh[j] <- rhat(x); es[j] <- ess_bulk(x)
  }
  st <- do.call(rbind, lapply(fit$chains, `[[`, "stats"))
  row <- data.frame(model = name, params = P, max_z_mean = max(abs(zm)), max_z_sd = max(abs(zs)),
                    max_rhat = max(rh), min_ess_bulk = round(min(es)), divergences = sum(st$divergent),
                    mean_depth = mean(st$depth),
                    seconds = sum(vapply(fit$chains, `[[`, numeric(1), "elapsed")))
  ok <- row$max_z_mean < 4.5 && row$max_z_sd < 4.5 && row$max_rhat < 1.01 && row$divergences == 0
  row$ok <- ok
  if (!ok) failed <<- TRUE
  results[[name]] <<- row
  print(row, row.names = FALSE, digits = 3)
}

# 1. normal mean, known variance ------------------------------------------
y <- rnorm(15, 1.7, 2)
m <- nm_model(list(mu = real()), function(p, d) normal_lpdf(d$y, p$mu, 2) + normal_lpdf(p$mu, 1, 3),
              data = list(y = y), name = "normal-normal")
prec <- 1 / 9 + 15 / 4
check("normal-normal", nuts(m, seed = 1), (1 / 9 + sum(y) / 4) / prec, sqrt(1 / prec))

# 2. beta-binomial through a logit-transformed bounded parameter ------------
m <- nm_model(list(p = bounded(0, 1)), function(p, d)
  beta_lpdf(p$p, 2, 3) + d$k * log(p$p) + (d$n - d$k) * log1p(-p$p),
  data = list(k = 7, n = 20), name = "beta-binomial")
a <- 9; b <- 16
check("beta-binomial", nuts(m, seed = 2), a / (a + b), sqrt(a * b / ((a + b)^2 * (a + b + 1))))

# 3. gamma-poisson through a log-transformed positive parameter -------------
cnt <- rpois(12, 4.2)
m <- nm_model(list(lambda = positive()), function(p, d)
  gamma_lpdf(p$lambda, 3, 0.5) + sum(d$k * log(p$lambda) - p$lambda) - sum(lgamma(d$k + 1)),
  data = list(k = cnt), name = "gamma-poisson")
sh <- 3 + sum(cnt); rt <- 0.5 + 12
check("gamma-poisson", nuts(m, seed = 3), sh / rt, sqrt(sh) / rt)

# 4. dirichlet-multinomial through the stick-breaking simplex ----------------
alpha <- c(1, 2, 3, 1); counts <- c(10, 4, 7, 1)
m <- nm_model(list(theta = simplex(4)), function(p, d)
  dirichlet_lpdf(p$theta, d$alpha) + sum(d$counts * log(p$theta)),
  data = list(alpha = alpha, counts = counts), name = "dirichlet-multinomial")
A <- alpha + counts; A0 <- sum(A)
check("dirichlet-multinomial", nuts(m, seed = 4), A / A0, sqrt(A * (A0 - A) / (A0^2 * (A0 + 1))))

# 5. strongly correlated gaussian (rho = 0.95) ------------------------------
S <- matrix(c(1, 0.95 * 3, 0.95 * 3, 9), 2); Pm <- solve(S); mu0 <- c(-1, 4)
m <- nm_model(list(x = real(2)), function(p, d) { r <- p$x - d$mu; -0.5 * sum(r * ad_vec(d$P %*% r)) },
              data = list(P = Pm, mu = mu0), name = "correlated-2d")
check("correlated-2d", nuts(m, seed = 5), mu0, sqrt(diag(S)))

# 6. 50-d gaussian with scales spanning two orders of magnitude --------------
sds <- exp(seq(log(0.1), log(10), length.out = 50))
m <- nm_model(list(x = real(50)), function(p, d) normal_lpdf(p$x, 0, d$s),
              data = list(s = sds), name = "scaled-50d")
check("scaled-50d", nuts(m, seed = 6), numeric(50), sds)

# 7. heavy tails: student-t with 5 degrees of freedom ------------------------
m <- nm_model(list(x = real(3)), function(p, d) student_t_lpdf(p$x, 5, 0, 1), name = "student-t5")
check("student-t5", nuts(m, seed = 7, iter = 2000), numeric(3), rep(sqrt(5 / 3), 3))

res <- do.call(rbind, results)
write.csv(res, "out/posteriors.csv", row.names = FALSE)
cat(sprintf("\nExact-posterior tests: %d/%d models pass\n", sum(res$ok), nrow(res)))
if (failed) quit(status = 1)
