# nutmeg: a No-U-Turn Sampler with its own reverse-mode autodiff, in base R.
# source("path/to/nutmeg.R") loads everything into the global environment.
local({
  files <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
  me <- Filter(function(p) basename(p) == "nutmeg.R", files)
  here <- if (length(me)) dirname(me[[length(me)]]) else "."
  for (f in c("ad.R", "model.R", "nuts.R", "diagnostics.R"))
    sys.source(file.path(here, "R", f), envir = globalenv())
})
