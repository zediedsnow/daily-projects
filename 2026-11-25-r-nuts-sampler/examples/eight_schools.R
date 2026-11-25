# Eight schools (Rubin 1981): the classic funnel.  The centred
# parameterisation produces divergent transitions concentrated in the neck of
# the funnel; the non-centred one samples cleanly.  Writes screenshot.png.
source("nutmeg.R")
options(nutmeg.cores = 2L, width = 160)
y     <- c(28, 8, -3, 7, -1, 1, 18, 12)
sigma <- c(15, 10, 16, 11, 9, 11, 10, 18)
dat <- list(y = y, sigma = sigma)

centred <- nm_model(list(mu = real(), tau = positive(), theta = real(8)), function(p, d)
  normal_lpdf(p$mu, 0, 5) + cauchy_lpdf(p$tau, 0, 5) +
  normal_lpdf(p$theta, p$mu, p$tau) + normal_lpdf(d$y, p$theta, d$sigma),
  data = dat, name = "eight schools (centred)")

noncentred <- nm_model(list(mu = real(), tau = positive(), eta = real(8)), function(p, d) {
  theta <- p$mu + p$tau * p$eta
  normal_lpdf(p$mu, 0, 5) + cauchy_lpdf(p$tau, 0, 5) +
  normal_lpdf(p$eta, 0, 1) + normal_lpdf(d$y, theta, d$sigma)
}, data = dat, name = "eight schools (non-centred)")

fc <- nuts(centred, seed = 8, delta = 0.8)
print(fc)
fn <- nuts(noncentred, seed = 8)
print(fn)
cat(sprintf("E-BFMI centred: %s | non-centred: %s\n",
            paste(round(ebfmi(fc), 2), collapse = " "), paste(round(ebfmi(fn), 2), collapse = " ")))

pull <- function(fit, j) as.vector(fit$draws[, j, ])
div  <- function(fit) unlist(lapply(fit$chains, function(ch) ch$stats$divergent))
saveRDS(list(centred = fc$draws, noncentred = fn$draws), "out/eight_schools_draws.rds")

png("screenshot.png", width = 1500, height = 620, res = 120, type = "cairo")
par(mfrow = c(1, 2), mar = c(4.2, 4.2, 3, 1), bg = "#fbfaf7", family = "sans")
panel <- function(fit, theta1, title) {
  lt <- log(pull(fit, "tau")); d <- div(fit)
  plot(theta1, lt, pch = 16, cex = 0.45, col = adjustcolor("#2f5d8a", 0.35),
       xlab = expression(theta[1]), ylab = expression(log ~ tau), main = title,
       xlim = c(-25, 50), ylim = c(-7, 4), las = 1)
  points(theta1[d], lt[d], pch = 16, cex = 0.9, col = "#d1495b")
  legend("bottomright", bty = "n", pch = 16, col = c("#2f5d8a", "#d1495b"),
         legend = c("draws", sprintf("divergent (%d)", sum(d))))
}
panel(fc, pull(fc, "theta[1]"), "Centred: NUTS hits the funnel neck")
panel(fn, pull(fn, "mu") + pull(fn, "tau") * pull(fn, "eta[1]"), "Non-centred: same model, funnel sampled cleanly")
dev.off()
cat("wrote screenshot.png\n")
