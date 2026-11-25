# Differential test against Stan itself (rstan): same models, same priors,
# same data.  Posterior means and sds must agree within combined Monte-Carlo
# error, and the adapted samplers should look alike (step size, tree depth).
source("nutmeg.R")
if (!requireNamespace("rstan", quietly = TRUE)) { cat("rstan not installed; skipping\n"); quit() }
suppressPackageStartupMessages(library(rstan))
options(nutmeg.cores = 2L, width = 160, mc.cores = 2L)
rstan_options(auto_write = FALSE)
if (!nzchar(rstan_options("boost_lib")) && dir.exists("/usr/include/boost")) rstan_options(boost_lib = "/usr/include")  # Debian packaging
set.seed(99)
failed <- FALSE; rows <- list()

compare <- function(name, fit_nm, fit_st, pars) {
  sa <- rstan::extract(fit_st, permuted = FALSE)          # iter x chain x par
  sp <- rstan::get_sampler_params(fit_st, inc_warmup = FALSE)
  st_nm <- do.call(rbind, lapply(fit_nm$chains, `[[`, "stats"))
  out <- do.call(rbind, lapply(pars, function(p) {
    xa <- matrix(fit_nm$draws[, p, ], dim(fit_nm$draws)[1])
    xb <- sa[, , p]
    va <- as.vector(xa); vb <- as.vector(xb)
    z_mean <- (mean(va) - mean(vb)) / sqrt(mcse_mean(xa)^2 + mcse_mean(xb)^2)
    # sd comparison via the mcse of the second moment
    m2 <- function(x, mu) matrix((x - mu)^2, nrow(x))
    z_sd <- (var(va) - var(vb)) / sqrt(mcse_mean(m2(xa, mean(va)))^2 + mcse_mean(m2(xb, mean(vb)))^2)
    data.frame(model = name, param = p, nutmeg_mean = mean(va), stan_mean = mean(vb),
               nutmeg_sd = sd(va), stan_sd = sd(vb), z_mean = z_mean, z_var = z_sd)
  }))
  print(out, row.names = FALSE, digits = 3)
  cat(sprintf("  step size  nutmeg %s | stan %s\n",
      paste(signif(vapply(fit_nm$chains, `[[`, numeric(1), "step_size"), 3), collapse = " "),
      paste(signif(vapply(sp, function(s) s[1, "stepsize__"], numeric(1)), 3), collapse = " ")))
  cat(sprintf("  mean tree depth  nutmeg %.2f | stan %.2f;  leapfrogs/draw nutmeg %.1f | stan %.1f;  divergences nutmeg %d | stan %d\n",
      mean(st_nm$depth), mean(unlist(lapply(sp, function(s) s[, "treedepth__"]))),
      mean(st_nm$n_leapfrog), mean(unlist(lapply(sp, function(s) s[, "n_leapfrog__"]))),
      sum(st_nm$divergent), sum(unlist(lapply(sp, function(s) s[, "divergent__"])))))
  if (max(abs(out$z_mean)) > 4.5 || max(abs(out$z_var)) > 4.5) failed <<- TRUE
  rows[[name]] <<- out
}

# ---- 1. eight schools, non-centred -----------------------------------------
y <- c(28, 8, -3, 7, -1, 1, 18, 12); sigma <- c(15, 10, 16, 11, 9, 11, 10, 18)
es_stan <- "
data { int J; vector[J] y; vector<lower=0>[J] sigma; }
parameters { real mu; real<lower=0> tau; vector[J] eta; }
model { mu ~ normal(0, 5); tau ~ cauchy(0, 5); eta ~ normal(0, 1);
        y ~ normal(mu + tau * eta, sigma); }"
es_nm <- nm_model(list(mu = real(), tau = positive(), eta = real(8)), function(p, d)
  normal_lpdf(p$mu, 0, 5) + cauchy_lpdf(p$tau, 0, 5) + normal_lpdf(p$eta, 0, 1) +
  normal_lpdf(d$y, p$mu + p$tau * p$eta, d$sigma), data = list(y = y, sigma = sigma), name = "eight schools")
st <- stan(model_code = es_stan, data = list(J = 8, y = y, sigma = sigma), chains = 4,
           iter = 2000, seed = 1, refresh = 0)
compare("eight-schools", nuts(es_nm, seed = 21), st, c("mu", "tau", paste0("eta[", 1:8, "]")))

# ---- 2. logistic regression, 400 rows x 5 predictors -------------------------
n <- 400; X <- cbind(1, matrix(rnorm(n * 4), n)); beta_true <- c(-0.5, 1.2, -0.8, 0.3, 0)
yb <- rbinom(n, 1, plogis(X %*% beta_true))
lr_stan <- "
data { int N; int K; matrix[N, K] X; array[N] int<lower=0,upper=1> y; }
parameters { vector[K] beta; }
model { beta ~ normal(0, 2.5); y ~ bernoulli_logit(X * beta); }"
lr_nm <- nm_model(list(beta = real(5)), function(p, d)
  normal_lpdf(p$beta, 0, 2.5) + bernoulli_logit_lpmf(d$y, ad_vec(d$X %*% p$beta)),
  data = list(X = X, y = yb), name = "logistic regression")
st <- stan(model_code = lr_stan, data = list(N = n, K = 5, X = X, y = yb), chains = 4,
           iter = 2000, seed = 2, refresh = 0)
compare("logistic", nuts(lr_nm, seed = 22), st, paste0("beta[", 1:5, "]"))

# ---- 3. poisson regression with a varying intercept per group ---------------
g <- rep(1:6, each = 15); xg <- rnorm(90); a_true <- rnorm(6, 0, 0.7)
cnt <- rpois(90, exp(1 + a_true[g] + 0.4 * xg))
pr_stan <- "
data { int N; int G; array[N] int<lower=1,upper=G> g; vector[N] x; array[N] int y; }
parameters { real a0; real b; real<lower=0> s; vector[G] z; }
model { a0 ~ normal(0, 2); b ~ normal(0, 1); s ~ exponential(1); z ~ normal(0, 1);
        y ~ poisson_log(a0 + s * z[g] + b * x); }"
pr_nm <- nm_model(list(a0 = real(), b = real(), s = positive(), z = real(6)), function(p, d)
  normal_lpdf(p$a0, 0, 2) + normal_lpdf(p$b, 0, 1) + exponential_lpdf(p$s, 1) + normal_lpdf(p$z, 0, 1) +
  poisson_log_lpmf(d$y, p$a0 + p$s * p$z[d$g] + p$b * d$x),
  data = list(g = g, x = xg, y = cnt), name = "poisson varying intercepts")
st <- stan(model_code = pr_stan, data = list(N = 90, G = 6, g = g, x = xg, y = cnt), chains = 4,
           iter = 2000, seed = 3, refresh = 0)
compare("poisson-hier", nuts(pr_nm, seed = 23), st, c("a0", "b", "s", paste0("z[", 1:6, "]")))

all <- do.call(rbind, rows)
write.csv(all, "out/vs_stan.csv", row.names = FALSE)
cat(sprintf("\nnutmeg vs Stan: %d parameters across 3 models, max |z| mean %.2f, max |z| variance %.2f -> %s\n",
            nrow(all), max(abs(all$z_mean)), max(abs(all$z_var)), if (failed) "FAIL" else "agree"))
if (failed) quit(status = 1)
