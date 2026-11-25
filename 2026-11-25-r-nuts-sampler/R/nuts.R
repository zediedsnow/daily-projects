# ---------------------------------------------------------------------------
# The No-U-Turn Sampler, multinomial variant (Betancourt 2017, as in Stan):
#  * trajectories double forwards/backwards at random until a generalised
#    no-U-turn criterion fires on the whole tree or any subtree, including
#    the two extra checks across each merge boundary;
#  * the draw is picked from the whole trajectory with weights exp(-H),
#    biased-progressively towards the newest subtree;
#  * divergences are flagged when the energy error exceeds 1000.
# Warm-up follows Stan: dual-averaging step size (target accept 0.8) and a
# diagonal metric learned in doubling windows (75 / 25.. / 50 buffers).
# ---------------------------------------------------------------------------

lse2 <- function(a, b) {
  if (a == -Inf) return(b); if (b == -Inf) return(a)
  m <- max(a, b); m + log(exp(a - m) + exp(b - m))
}

nuts_chain <- function(model, iter = 1000L, warmup = 1000L, init = NULL,
                       delta = 0.8, max_depth = 10L, seed = NULL,
                       init_radius = 2, adapt_metric = TRUE) {
  if (!is.null(seed)) set.seed(seed)
  d <- model$dim
  lpg <- model$logp_grad
  st <- new.env()                       # per-transition bookkeeping
  inv_m <- rep(1, d)

  # ---- point evaluation with error tolerance -------------------------------
  make_point <- function(q) {
    r <- tryCatch(lpg(q), error = function(e) list(value = -Inf, grad = rep(NA_real_, d)))
    lp <- r$value
    if (!is.finite(lp) || any(!is.finite(r$grad))) lp <- -Inf
    list(q = q, g = r$grad, lp = lp)
  }
  if (is.null(init)) {
    for (k in 1:100) {
      z0 <- make_point(runif(d, -init_radius, init_radius))
      if (is.finite(z0$lp)) break
    }
  } else z0 <- make_point(init)
  if (!is.finite(z0$lp)) stop("could not find a finite initial point")

  hamiltonian <- function(z, p) -z$lp + 0.5 * sum(inv_m * p * p)
  leapfrog <- function(z, p, eps) {
    p <- p + 0.5 * eps * z$g
    if (any(!is.finite(p))) return(list(z = list(q = z$q, g = z$g, lp = -Inf), p = p))
    z <- make_point(z$q + eps * inv_m * p)
    if (is.finite(z$lp)) p <- p + 0.5 * eps * z$g
    list(z = z, p = p)
  }
  uturn_ok <- function(ps_minus, ps_plus, rho)
    sum(ps_plus * rho) > 0 && sum(ps_minus * rho) > 0

  # ---- recursive tree building ---------------------------------------------
  # Returns the subtree's: validity, final integrator state (z,p), proposal,
  # boundary momenta (b = first built, e = last built) and their sharp
  # versions, summed momentum rho and log total weight.
  build_tree <- function(depth, z, p, sign, eps, H0) {
    if (depth == 0L) {
      lf <- leapfrog(z, p, sign * eps)
      st$n_leapfrog <- st$n_leapfrog + 1L
      h <- if (is.finite(lf$z$lp)) hamiltonian(lf$z, lf$p) else Inf
      if (is.nan(h)) h <- Inf
      if (h - H0 > 1000) st$divergent <- TRUE
      st$sum_metro <- st$sum_metro + (if (H0 - h > 0) 1 else exp(H0 - h))
      ps <- inv_m * lf$p
      return(list(valid = !st$divergent, z = lf$z, p = lf$p, prop = lf$z,
                  pb = lf$p, pe = lf$p, psb = ps, pse = ps, rho = lf$p, lw = H0 - h))
    }
    a <- build_tree(depth - 1L, z, p, sign, eps, H0)
    if (!a$valid) return(a)
    b <- build_tree(depth - 1L, a$z, a$p, sign, eps, H0)
    if (!b$valid) return(b)
    lw <- lse2(a$lw, b$lw)
    prop <- if (runif(1) < exp(b$lw - lw)) b$prop else a$prop   # uniform within subtree
    rho <- a$rho + b$rho
    ok <- uturn_ok(a$psb, b$pse, rho) &&
          uturn_ok(a$psb, b$psb, a$rho + b$pb) &&
          uturn_ok(a$pse, b$pse, b$rho + a$pe)
    list(valid = ok, z = b$z, p = b$p, prop = prop, pb = a$pb, pe = b$pe,
         psb = a$psb, pse = b$pse, rho = rho, lw = lw)
  }

  transition <- function(z, eps) {
    p0 <- rnorm(d) / sqrt(inv_m)
    H0 <- hamiltonian(z, p0)
    st$n_leapfrog <- 0L; st$sum_metro <- 0; st$divergent <- FALSE
    ps0 <- inv_m * p0
    # the trajectory's two ends: integrator state, momentum, sharp momentum
    L <- list(z = z, p = p0, ps = ps0); R <- L
    rho <- p0; lw <- 0; sample <- z; depth <- 0L
    while (depth < max_depth) {
      if (runif(1) > 0.5) {                     # extend forwards
        t <- build_tree(depth, R$z, R$p, +1, eps, H0)
        if (!t$valid) break
        oldL <- L; oldR <- R
        R <- list(z = t$z, p = t$p, ps = t$pse)
        new_first <- list(p = t$pb, ps = t$psb); old_adj <- oldR; far <- oldL
      } else {                                  # extend backwards
        t <- build_tree(depth, L$z, L$p, -1, eps, H0)
        if (!t$valid) break
        oldL <- L; oldR <- R
        L <- list(z = t$z, p = t$p, ps = t$pse)
        new_first <- list(p = t$pb, ps = t$psb); old_adj <- oldL; far <- oldR
      }
      depth <- depth + 1L
      # biased progressive sampling: prefer the new half
      if (t$lw > lw || runif(1) < exp(t$lw - lw)) sample <- t$prop
      lw <- lse2(lw, t$lw)
      rho_old <- rho
      rho <- rho_old + t$rho
      ok <- uturn_ok(L$ps, R$ps, rho) &&
            uturn_ok(far$ps, new_first$ps, rho_old + new_first$p) &&
            uturn_ok(old_adj$ps, t$pse, t$rho + old_adj$p)
      if (!ok) break
    }
    list(z = sample, accept = st$sum_metro / max(1L, st$n_leapfrog),
         depth = depth, n_leapfrog = st$n_leapfrog, divergent = st$divergent,
         energy = H0)
  }

  # ---- step size heuristic (Stan's init_stepsize) ---------------------------
  init_stepsize <- function(z, eps) {
    dH <- function(eps) {
      p <- rnorm(d) / sqrt(inv_m)
      H0 <- hamiltonian(z, p); lf <- leapfrog(z, p, eps)
      h <- if (is.finite(lf$z$lp)) hamiltonian(lf$z, lf$p) else Inf
      if (is.nan(h)) -Inf else H0 - h
    }
    dir <- if (dH(eps) > log(0.8)) 1 else -1
    repeat {
      x <- dH(eps)
      if (dir == 1 && !(x > log(0.8))) break
      if (dir == -1 && !(x < log(0.8))) break
      eps <- if (dir == 1) 2 * eps else 0.5 * eps
      if (eps > 1e7 || eps < 1e-12) stop("step size heuristic failed")
    }
    eps
  }

  # ---- dual averaging ------------------------------------------------------
  da <- new.env()
  da_restart <- function(eps) { da$mu <- log(10 * eps); da$sbar <- 0; da$xbar <- 0; da$k <- 0 }
  da_learn <- function(a) {
    da$k <- da$k + 1; a <- min(1, a)
    eta <- 1 / (da$k + 10)
    da$sbar <- (1 - eta) * da$sbar + eta * (delta - a)
    x <- da$mu - da$sbar * sqrt(da$k) / 0.05
    w <- da$k ^ (-0.75)
    da$xbar <- (1 - w) * da$xbar + w * x
    exp(x)
  }

  # ---- windowed metric adaptation schedule ----------------------------------
  init_buf <- 75L; term_buf <- 50L; base_win <- 25L
  if (warmup < 20L) adapt_metric <- FALSE
  if (warmup < init_buf + term_buf + base_win) {        # Stan's small-warmup fallback
    init_buf <- as.integer(0.15 * warmup); term_buf <- as.integer(0.1 * warmup)
    base_win <- warmup - init_buf - term_buf
  }
  win_size <- base_win; win_end <- init_buf + base_win - 1L
  next_window <- function(k) {
    if (win_end == warmup - term_buf - 1L) return()
    win_size <<- win_size * 2L
    win_end <<- k + win_size
    if (win_end != warmup - term_buf - 1L && win_end + 2L * win_size >= warmup - term_buf)
      win_end <<- warmup - term_buf - 1L
  }
  wsum <- numeric(d); wsq <- numeric(d); wn <- 0L    # Welford estimator

  # ---- run ------------------------------------------------------------------
  z <- z0
  eps <- init_stepsize(z, 1); da_restart(eps)
  total <- warmup + iter
  draws <- matrix(NA_real_, iter, d, dimnames = list(NULL, model$labels))
  stats <- data.frame(accept = numeric(iter), depth = integer(iter),
                      n_leapfrog = integer(iter), divergent = logical(iter),
                      lp = numeric(iter), energy = numeric(iter))
  warm_div <- 0L
  t0 <- proc.time()[["elapsed"]]
  for (k in 0:(total - 1L)) {
    tr <- transition(z, eps)
    z <- tr$z
    if (k < warmup) {
      warm_div <- warm_div + tr$divergent
      eps <- da_learn(tr$accept)
      if (adapt_metric && k >= init_buf && k < warmup - term_buf) {
        wn <- wn + 1L; dlt <- z$q - wsum; wsum <- wsum + dlt / wn; wsq <- wsq + dlt * (z$q - wsum)
        if (k == win_end) {
          v <- wsq / (wn - 1)
          inv_m <- (wn / (wn + 5)) * v + 1e-3 * (5 / (wn + 5))
          wsum[] <- 0; wsq[] <- 0; wn <- 0L
          next_window(k)
          eps <- init_stepsize(z, eps); da_restart(eps)
        }
      }
      if (k == warmup - 1L) eps <- exp(da$xbar)
    } else {
      i <- k - warmup + 1L
      draws[i, ] <- z$q
      stats[i, ] <- list(tr$accept, tr$depth, tr$n_leapfrog, tr$divergent, z$lp, tr$energy)
    }
  }
  elapsed <- proc.time()[["elapsed"]] - t0
  constrained <- t(apply(draws, 1, model$constrained))
  if (d == 1L || is.null(dim(constrained))) constrained <- matrix(constrained, ncol = length(model$constrained(draws[1, ])))
  colnames(constrained) <- constrained_labels(model)
  list(draws = constrained, unconstrained = draws, stats = stats, step_size = eps,
       inv_metric = inv_m, elapsed = elapsed, warmup_divergences = warm_div)
}

constrained_labels <- function(model) {
  unlist(lapply(names(model$params), function(nm) {
    d <- model$params[[nm]]$dim
    if (d == 1L) nm else paste0(nm, "[", seq_len(d), "]")
  }))
}

# Run several chains (in parallel processes when available).
nuts <- function(model, chains = 4L, iter = 1000L, warmup = 1000L, seed = 1L,
                 cores = getOption("nutmeg.cores", 2L), ...) {
  run <- function(c) nuts_chain(model, iter = iter, warmup = warmup, seed = seed * 1000L + c, ...)
  fits <- if (cores > 1L && .Platform$OS.type == "unix")
    parallel::mclapply(seq_len(chains), run, mc.cores = cores, mc.set.seed = FALSE)
  else lapply(seq_len(chains), run)
  bad <- vapply(fits, function(f) inherits(f, "try-error"), logical(1))
  if (any(bad)) stop(fits[[which(bad)[1]]])
  structure(list(model = model, chains = fits,
    draws = simplify2array(lapply(fits, `[[`, "draws"))),   # iter x param x chain
    class = "nm_fit")
}
