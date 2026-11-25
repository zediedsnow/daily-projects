# ---------------------------------------------------------------------------
# Models: constrained parameters, change-of-variables Jacobians, and a small
# library of log densities.  Everything here is written with plain R
# arithmetic, so the same code runs on numbers (to report draws) and on adv
# nodes (to get gradients).
# ---------------------------------------------------------------------------

LOG_SQRT_2PI <- 0.5 * log(2 * pi)

# --- log densities (summed over elements, constants included) --------------
normal_lpdf <- function(y, mu, sigma)
  sum(-0.5 * ((y - mu) / sigma) ^ 2 - log(sigma) - LOG_SQRT_2PI)
lognormal_lpdf <- function(y, mu, sigma) normal_lpdf(log(y), mu, sigma) - sum(log(y))
cauchy_lpdf <- function(y, mu, s) sum(-log(pi) - log(s) - log1p(((y - mu) / s) ^ 2))
student_t_lpdf <- function(y, nu, mu, s)
  sum(lgamma((nu + 1) / 2) - lgamma(nu / 2) - 0.5 * log(nu * pi) - log(s) -
      (nu + 1) / 2 * log1p(((y - mu) / s) ^ 2 / nu))
exponential_lpdf <- function(y, rate) sum(log(rate) - rate * y)
gamma_lpdf <- function(y, shape, rate)
  sum(shape * log(rate) - lgamma(shape) + (shape - 1) * log(y) - rate * y)
beta_lpdf <- function(y, a, b)
  sum(lgamma(a + b) - lgamma(a) - lgamma(b) + (a - 1) * log(y) + (b - 1) * log1p(-y))
bernoulli_logit_lpmf <- function(y, eta) sum(y * eta - softplus(eta))
binomial_logit_lpmf <- function(k, n, eta)
  sum(lchoose(n, k)) + sum(k * eta - n * softplus(eta))
poisson_log_lpmf <- function(k, eta) sum(k * eta - exp(eta)) - sum(lgamma(k + 1))

# --- parameter declarations -------------------------------------------------
real     <- function(n = 1L) list(type = "real", n = n, dim = n)
positive <- function(n = 1L) list(type = "positive", n = n, dim = n)
bounded  <- function(lo, hi, n = 1L) list(type = "bounded", n = n, dim = n, lo = lo, hi = hi)
simplex  <- function(K) list(type = "simplex", n = K - 1L, dim = K)

# Map one block of unconstrained values to its constrained value and the
# log |Jacobian| of that map.
constrain_one <- function(spec, u) {
  switch(spec$type,
    real = list(x = u, lj = 0),
    positive = list(x = exp(u), lj = sum(u)),
    bounded = {
      z <- inv_logit(u)
      w <- spec$hi - spec$lo
      # log z = -softplus(-u), log(1-z) = -softplus(u): stable in the tails
      list(x = spec$lo + w * z, lj = sum(log(w) - softplus(-u) - softplus(u)))
    },
    simplex = {           # Stan's stick-breaking transform
      K <- spec$dim
      x <- NULL; lj <- 0; left <- 1
      for (k in seq_len(K - 1L)) {
        uk <- u[k] - log(K - k)
        z <- inv_logit(uk)
        xk <- left * z
        lj <- lj - softplus(-uk) - softplus(uk) + log(left)
        x <- if (is.null(x)) xk else ad_c(x, xk)
        left <- left - xk
      }
      list(x = ad_c(x, left), lj = lj)
    })
}

# Define a model.  `log_density(p, data)` receives a named list of
# constrained parameters and returns the unnormalised log posterior.
nm_model <- function(params, log_density, data = NULL, name = "model") {
  force(data); force(log_density)
  sizes  <- as.integer(vapply(params, function(s) as.numeric(s$n), numeric(1)))
  ends   <- cumsum(sizes); starts <- ends - sizes + 1L
  labels <- unlist(lapply(names(params), function(nm) {
    d <- params[[nm]]$n
    if (d == 1L) nm else paste0(nm, "[", seq_len(d), "]")
  }))
  constrain <- function(theta, jacobian = TRUE) {
    out <- vector("list", length(params)); names(out) <- names(params); lj <- 0
    for (i in seq_along(params)) {
      u <- if (starts[i] == ends[i] && sizes[i] == 1L) theta[starts[i]] else theta[starts[i]:ends[i]]
      r <- constrain_one(params[[i]], u)
      out[[i]] <- r$x
      lj <- lj + r$lj
    }
    list(p = out, lj = lj)
  }
  logp <- function(theta) {
    c <- constrain(theta)
    log_density(c$p, data) + c$lj
  }
  structure(list(
    name = name, dim = sum(sizes), labels = labels, params = params,
    logp = logp,
    logp_grad = function(theta) ad_grad(logp, theta),
    constrained = function(theta) unlist(lapply(constrain(theta)$p, val), use.names = FALSE)
  ), class = "nm_model")
}
dirichlet_lpdf <- function(x, alpha) lgamma(sum(alpha)) - sum(lgamma(alpha)) + sum((alpha - 1) * log(x))
