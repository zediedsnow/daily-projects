# Bayesian logistic regression in a dozen lines, checked against glm().
source("nutmeg.R")
set.seed(1)
n <- 300
X <- cbind(1, age = rnorm(n), dose = rnorm(n))
y <- rbinom(n, 1, plogis(X %*% c(-1, 0.8, 1.5)))

model <- nm_model(
  params = list(beta = real(3)),
  log_density = function(p, d)
    normal_lpdf(p$beta, 0, 5) +                         # weakly-informative prior
    bernoulli_logit_lpmf(d$y, ad_vec(d$X %*% p$beta)),  # likelihood
  data = list(X = X, y = y), name = "logistic regression")

fit <- nuts(model, chains = 4, iter = 1000, warmup = 1000)
print(fit)
cat("\nglm() maximum likelihood for comparison:\n")
print(round(coef(glm(y ~ X - 1, family = binomial)), 3))
