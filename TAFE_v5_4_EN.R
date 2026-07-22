# ============================================================
#  ENSEMBLE FORECAST v5.1 — OPTIMIZED (English version)
#  Improvements over v5:
#    1. TA objective function changed from MSE → SMAPE
#       (eliminates price-scale bias in MXN²)
#    2. Temperature parameters scaled relative to smape_pv
#       (consistent behavior across assets of different scales)
#    3. Weight caps: ARFIMA ≤ 0.10, RF ≤ 0.20
#       (prevents consistently weak models from dominating)
#  Improvements over v4_3 (carried from v5):
#    4. No double model fitting: each model is trained ONCE
#    5. TA_mod fully self-contained (no global variable leakage)
#    6. 30 TA restarts run in parallel via parallel::parLapply
#    7. OOS block: true out-of-sample forecasts on full series
#    8. compare_oos() for metric evaluation when actuals arrive
#  Methods : ETS, ARIMA, STL, NNAR, TBATS, ARFIMA, PROPHET, RF (8)
#  Benchmark: HybridModel
#  Ensembles : Comb_EW (1/8 equal weights), Comb_TA (TA weights)
# ============================================================

# ── Packages ─────────────────────────────────────────────────
library(forecast)
library(dplyr)
library(tsfeatures)
library(xts)
library(fpp2)
library(ggplot2)
library(tictoc)
library(tsbox)
library(tseries)
library(forecastHybrid)
library(MLmetrics)
library(Metrics)
library(gridExtra)
library(purrr)
library(lubridate)
library(scales)
library(tidyr)
library(reshape2)
library(prophet)
library(ranger)

# ── Parallelization packages ─────────────────────────────────
library(parallel)
library(doParallel)
library(foreach)

# ── Paths ────────────────────────────────────────────────────
datos <- read.csv(
  file   = "C:/DOCTORADO/ART 2025/ETFS/ETF_FIB_20_26/FIBRA_EFT_LIMPIOS_PROXY.csv",
  header = TRUE
)

dim(datos)
L <- nrow(datos)
C <- ncol(datos)

base_path  <- "C:/DOCTORADO/ART 2025/ETFS/ETF_FIB_20_26"
graf_path  <- file.path(base_path, "charts")
dir.create(graf_path, showWarnings = FALSE, recursive = TRUE)

# ── Available cores ───────────────────────────────────────────
N_CORES <- max(1L, detectCores() - 1L)
cat("Available cores:", N_CORES, "\n")

# ── OOS horizon (weeks to forecast out-of-sample) ────────────
H_OOS    <- 26L   # must match the number of rows in oos_actual_path
K_MODELS <- 5L    # top-K models selected per asset for TA ensemble
LAMBDA   <- 0.5   # OOS shrinkage: 0 = equal weight, 1 = pure TA weights
                  # shrinks OOS weights toward equal weighting to reduce
                  # overfitting risk when regime changes between IS and OOS
                  # (ranked by individual SMAPE on pseudo-validation)
                  # range: 3–8. Lower = more focused, Higher = more diverse.

# ── Path to actual OOS data (CSV: Date + one column per asset) ─
# Set to NULL to skip automatic comparison and chart with actuals.
oos_actual_path <- "C:/DOCTORADO/ART 2025/ETFS/ETF_FIB_20_26/FIBRA_EFT_MX_20_26_Wk_OOS.csv"

## ── Global structures ─────────────────────────────────────────
memoriaBest_global <- data.frame(matrix(0, nrow = 1, ncol = 10))
colnames(memoriaBest_global) <- c("ASSET", "SMAPE",
                                   "ETS", "ARIMA", "STL", "NNAR", "TBATS", "ARFIMA",
                                   "PROPHET", "RF")
forecasts_global <- data.frame()
error_metrics    <- data.frame()
series_info      <- data.frame()
forecasts_oos    <- data.frame()   # filled in OOS block

# ── Load actual OOS data if path is provided ─────────────────
actual_oos_data <- NULL
if (!is.null(oos_actual_path) && file.exists(oos_actual_path)) {
  actual_oos_data <- read.csv(oos_actual_path, header = TRUE)
  actual_oos_data$Date <- as.Date(actual_oos_data$Date)
  cat("Actual OOS data loaded:", nrow(actual_oos_data), "rows from", oos_actual_path, "\n")
} else {
  cat("No actual OOS data loaded (oos_actual_path is NULL or file not found).\n")
}

time_start <- Sys.time()

# ============================================================
# TA FUNCTIONS — FULLY SELF-CONTAINED
# ============================================================

# ── Weight generator (8 models, sum = 1) ─────────────────────
# Caps based on diagnostic: ARFIMA (pos 6) consistently worst,
# RF (pos 8) high variance — limit their maximum influence.
#   ETS   ARIMA  STL   NNAR  TBATS  ARFIMA  PROPHET  RF
W_MAX <- c(0.45,  0.45, 0.45, 0.45,  0.45,  0.45,   0.45,   0.45)

generator <- function() {
  s <- runif(8L, 0, 1)
  w <- s / sum(s)
  # Apply per-model caps and renormalize
  w <- pmin(w, W_MAX)
  w / sum(w)
}

# ── Linear combination over pseudo-validation fitted values ──
new_comb <- function(w, pv_ETS, pv_ARIMA, pv_STL, pv_NNAR,
                     pv_TBATS, pv_ARFIMA, pv_PROPHET, pv_RF) {
  pv_ETS     * w[1] + pv_ARIMA   * w[2] +
    pv_STL     * w[3] + pv_NNAR    * w[4] +
    pv_TBATS   * w[5] + pv_ARFIMA  * w[6] +
    pv_PROPHET * w[7] + pv_RF      * w[8]
}

# ── Linear combination over test / OOS forecasts ─────────────
new_comb_fct <- function(w, f_ETS, f_ARIMA, f_STL, f_NNAR,
                         f_TBATS, f_ARFIMA, f_PROPHET, f_RF) {
  f_ETS     * w[1] + f_ARIMA   * w[2] +
    f_STL     * w[3] + f_NNAR    * w[4] +
    f_TBATS   * w[5] + f_ARFIMA  * w[6] +
    f_PROPHET * w[7] + f_RF      * w[8]
}

# ── Optimization error (SMAPE on pseudo-validation) ──────────
# Changed from MSE to SMAPE: aligns optimization metric with
# the evaluation metric, and removes price-scale bias (MXN²).
err_opt <- function(FctsOpts, pv_obs) smape(pv_obs, FctsOpts)

# ── TA_mod_self: single restart, fully self-contained ─────────
#    All parameters and data are passed explicitly.
#    Returns: c(best_SMAPE, w1, ..., w8)
TA_mod_self <- function(T0, Tf, alfa, gannma, Lk, err_initial,
                        pv_obs, pv_ETS, pv_ARIMA, pv_STL, pv_NNAR,
                        pv_TBATS, pv_ARFIMA, pv_PROPHET, pv_RF,
                        seed = NULL) {

  if (!is.null(seed)) set.seed(seed)

  Tk       <- T0
  Tolk     <- err_initial      # tolerance relative to initial SMAPE
  k        <- 0L
  Xold     <- err_initial
  BestSol  <- c(err_initial, rep(1/8, 8))
  BestGlob <- BestSol

  while (Tk >= Tf) {
    while (k < Lk) {
      nu_sol <- generator()
      FctTA  <- new_comb(nu_sol, pv_ETS, pv_ARIMA, pv_STL, pv_NNAR,
                         pv_TBATS, pv_ARFIMA, pv_PROPHET, pv_RF)
      Xnew   <- err_opt(FctTA, pv_obs)
      Energy <- Xnew - Xold

      if (Energy < 0) {
        if (Xnew < BestGlob[1]) {
          BestGlob <- c(Xnew, nu_sol)
          BestSol  <- BestGlob
        }
        Xold <- Xnew
      } else if (Energy <= Tolk) {
        BestSol <- c(Xnew, nu_sol)
        Xold    <- Xnew
      }
      k <- k + 1L
    }
    Tk   <- Tk   * alfa
    Tolk <- Tolk * gannma
    k    <- 0L
  }
  BestGlob
}

# ── run_TA_parallel: 30 restarts in parallel ──────────────────
#    Returns c(SMAPE, w1..w8) with the globally lowest SMAPE.
run_TA_parallel <- function(n_restarts = 3, n_cores = N_CORES,
                            T0, Tf, alfa = 0.985,
                            gannma = 0.979, Lk = 300,
                            err_pv, pv_obs,
                            pv_ETS, pv_ARIMA, pv_STL, pv_NNAR,
                            pv_TBATS, pv_ARFIMA, pv_PROPHET, pv_RF,
                            w_max = W_MAX) {
  # w_max: per-asset cap vector. Excluded models have cap = 0,
  # so generator() assigns them exactly 0 weight.
  W_MAX <- w_max   # shadow global W_MAX for cluster export

  seeds <- sample.int(1e6L, n_restarts)

  # Export required objects to the cluster
  cl <- makeCluster(min(n_cores, n_restarts))
  on.exit(stopCluster(cl), add = TRUE)

  clusterExport(cl,
    varlist = c("TA_mod_self", "generator", "new_comb", "err_opt",
                "W_MAX",
                "T0", "Tf", "alfa", "gannma", "Lk", "err_pv",
                "pv_obs", "pv_ETS", "pv_ARIMA", "pv_STL", "pv_NNAR",
                "pv_TBATS", "pv_ARFIMA", "pv_PROPHET", "pv_RF",
                "seeds"),
    envir = environment())

  clusterEvalQ(cl, library(Metrics))

  results <- parLapply(cl, seq_len(n_restarts), function(t) {
    TA_mod_self(
      T0 = T0, Tf = Tf, alfa = alfa, gannma = gannma,
      Lk = Lk, err_initial = err_pv,
      pv_obs = pv_obs,
      pv_ETS = pv_ETS, pv_ARIMA = pv_ARIMA, pv_STL = pv_STL,
      pv_NNAR = pv_NNAR, pv_TBATS = pv_TBATS, pv_ARFIMA = pv_ARFIMA,
      pv_PROPHET = pv_PROPHET, pv_RF = pv_RF,
      seed = seeds[t]
    )
  })

  # Select solution with lowest SMAPE
  best_err <- Inf
  best_sol <- results[[1]]
  for (res in results) {
    if (!is.na(res[1]) && res[1] < best_err) {
      best_err <- res[1]
      best_sol <- res
    }
  }
  best_sol   # c(SMAPE, w1..w8)
}

# ============================================================
# AUXILIARY FUNCTIONS — PROPHET, RF
# ============================================================

forecast_prophet <- function(train_ts, h) {
  t_tr  <- as.numeric(time(train_ts))
  ds_tr <- as.Date(date_decimal(t_tr))
  df_p  <- data.frame(ds = ds_tr, y = as.numeric(train_ts))

  suppressMessages({
    m <- prophet(
      df_p,
      weekly.seasonality  = TRUE,
      yearly.seasonality  = TRUE,
      daily.seasonality   = FALSE,
      seasonality.mode    = "multiplicative",
      uncertainty.samples = 0
    )
    fut  <- make_future_dataframe(m, periods = h, freq = "week")
    pred <- predict(m, fut)
  })

  yhat      <- tail(pred$yhat,        h)
  yhat_lo95 <- tail(pred$yhat_lower,  h)
  yhat_hi95 <- tail(pred$yhat_upper,  h)

  list(mean   = yhat,
       lower  = yhat_lo95,
       upper  = yhat_hi95,
       fitted = head(pred$yhat, nrow(df_p)))
}

make_lag_df <- function(y_vec, n_lags = 52L) {
  n <- length(y_vec)
  if (n <= n_lags) stop("Series too short for the specified n_lags")
  mat <- matrix(NA_real_, nrow = n - n_lags, ncol = n_lags + 1L)
  for (i in seq_len(nrow(mat))) {
    mat[i, 1:n_lags]    <- y_vec[i:(i + n_lags - 1L)]
    mat[i, n_lags + 1L] <- y_vec[i + n_lags]
  }
  df <- as.data.frame(mat)
  colnames(df) <- c(paste0("lag", n_lags:1L), "target")
  df
}

forecast_rf <- function(train_ts, h, n_lags = 52L) {
  y_tr <- as.numeric(train_ts)
  if (length(y_tr) <= n_lags + h)
    n_lags <- max(4L, floor(length(y_tr) * 0.3))

  df_tr    <- make_lag_df(y_tr, n_lags)
  features <- df_tr[, 1:n_lags, drop = FALSE]
  target   <- df_tr$target

  set.seed(42L)
  mod_rf <- ranger(
    x             = features,
    y             = target,
    num.trees     = 500L,
    min.node.size = 5L,
    keep.inbag    = FALSE,
    verbose       = FALSE
  )

  fitted_rf <- mod_rf$predictions   # OOB predictions

  # Iterative h-step ahead forecast
  history <- y_tr
  preds   <- numeric(h)
  for (i in seq_len(h)) {
    feat_i  <- tail(history, n_lags)
    newdata <- as.data.frame(t(feat_i))
    colnames(newdata) <- paste0("lag", n_lags:1L)
    preds[i] <- predict(mod_rf, newdata)$predictions
    history  <- c(history, preds[i])
  }

  fitted_full <- c(rep(NA_real_, n_lags), fitted_rf)
  list(mean = preds, fitted = fitted_full, model = mod_rf,
       n_lags = n_lags, history = y_tr)
}

# ── Helper: safe tail with NA mean-imputation ─────────────────
safe_tail <- function(x, n) {
  v <- as.numeric(x)
  v[is.na(v)] <- mean(v, na.rm = TRUE)
  tail(v, n)
}

# ── Helper: error metrics ─────────────────────────────────────
calc_m <- function(pred, obs) {
  list(MSE   = MSE(pred, obs),
       SMAPE = smape(obs, pred),
       RMSE  = RMSE(pred, obs),
       MAPE  = MAPE(pred, obs),
       MAE   = MAE(pred, obs))
}

# ============================================================
# PLOT HELPERS
# ============================================================
ts_to_df <- function(obj, label) {
  serie <- if (inherits(obj, "forecast")) obj$mean else as.ts(obj)
  t_dec <- as.numeric(time(as.ts(serie)))
  data.frame(date   = as.Date(date_decimal(t_dec)),
             value  = as.numeric(serie),
             method = label)
}

paper_theme <- theme_classic(base_size = 13) +
  theme(
    plot.title       = element_text(size = 15, face = "bold",   hjust = 0.5),
    plot.subtitle    = element_text(size = 11, hjust = 0.5,     colour = "grey40"),
    axis.title       = element_text(size = 13, face = "bold"),
    axis.text.x      = element_text(angle = 45, hjust = 1,      size = 10),
    legend.position  = "bottom",
    legend.title     = element_text(size = 11, face = "bold"),
    legend.text      = element_text(size = 10),
    panel.grid.major = element_line(color = "grey88", linewidth = 0.4),
    panel.grid.minor = element_blank()
  )

date_scale <- scale_x_date(date_breaks = "1 month", date_labels = "%Y-%m",
                            expand = expansion(mult = 0.02))

COLORS <- c(
  "Observed"         = "black",
  "ETS"              = "#1b9e77",
  "ARIMA"            = "#d95f02",
  "STL"              = "#7570b3",
  "NNAR"             = "#e7298a",
  "TBATS"            = "#66a61e",
  "ARFIMA"           = "#e6ab02",
  "Prophet"          = "#17becf",
  "RandomForest"     = "#8c564b",
  "Equally Weighted" = "#1f77b4",
  "HybridModel"      = "#2ca02c",
  "TA Optimized"     = "#d62728"
)

# ── In-sample plot set ────────────────────────────────────────
create_plots <- function(asset_name, test_ts, fcts, save_path = NULL) {

  df_obs   <- ts_to_df(test_ts,           "Observed")
  df_ets   <- ts_to_df(fcts$ETS,          "ETS")
  df_arima <- ts_to_df(fcts$ARIMA,        "ARIMA")
  df_stl   <- ts_to_df(fcts$STL,          "STL")
  df_nnar  <- ts_to_df(fcts$NNAR,         "NNAR")
  df_tbats <- ts_to_df(fcts$TBATS,        "TBATS")
  df_arfi  <- ts_to_df(fcts$ARFIMA,       "ARFIMA")
  df_proph <- data.frame(
    date   = as.Date(date_decimal(as.numeric(time(test_ts)))),
    value  = fcts$PROPHET_mean,
    method = "Prophet")
  df_rf    <- data.frame(
    date   = as.Date(date_decimal(as.numeric(time(test_ts)))),
    value  = fcts$RF_mean,
    method = "RandomForest")
  df_comb  <- ts_to_df(fcts$Combination,  "Equally Weighted")
  df_hybrid <- ts_to_df(fcts$HybridModel, "HybridModel")
  df_ta    <- ts_to_df(fcts$optTA_Fcts,   "TA Optimized")

  # ── Plot 1: individual models ──────────────────────────────
  # df_ind <- bind_rows(df_obs, df_ets, df_arima, df_stl,
  #                     df_nnar, df_tbats, df_arfi, df_proph, df_rf)
  # 
  # p1 <- ggplot(df_ind, aes(x = date, y = value, colour = method, linetype = method)) +
  #    geom_line(data = subset(df_ind, method != "Observed"),
  #              linewidth = 0.75, alpha = 0.9) +
  #   geom_line(data = subset(df_ind, method == "Observed"),
  #             linewidth = 1.2,  colour = "black") +
  #   date_scale +
  #   scale_colour_manual(name = "Method", values = COLORS) +
  #   scale_linetype_manual(name = "Method",
  #     values = c("Observed" = "solid", "ETS" = "dashed", "ARIMA" = "dashed",
  #                "STL" = "dashed",    "NNAR" = "twodash", "TBATS" = "dashed",
  #                "ARFIMA" = "dashed", "Prophet" = "twodash",
  #                "RandomForest" = "twodash")) +
  #   labs(title    = paste0("Individual Forecasts – ", asset_name),
  #        subtitle = "Dashed = individual models  |  Solid = Observed",
  #        x = "Date", y = "Price (MXN)") +
  #   paper_theme

  # ____ PLOT 1 INDIVIDUALES MODIFICADO_-------------------------
  # 1. Asegurar que 'method' sea un factor con un orden lógico
  df_ind <- bind_rows(df_obs, df_ets, df_arima, df_stl,
                      df_nnar, df_tbats, df_arfi, df_proph, df_rf)
  p1 <- ggplot(df_ind, aes(x = date, y = value, 
                           colour = method, 
                           linetype = method, 
                           shape = method)) +
    # 1. Capas de datos
    geom_line(data = subset(df_ind, method != "Observed"), 
              linewidth = 0.7, alpha = 0.8) +
    geom_point(data = subset(df_ind, method != "Observed"), 
               size = 1.5, alpha = 0.8) + 
    geom_line(data = subset(df_ind, method == "Observed"), 
              linewidth = 1.1, colour = "black", linetype = "solid") +
    
    # 2. Escalas (Mismo nombre para que se fusionen)
    scale_colour_manual(name = "Forecasting Method", values = COLORS) +
    scale_linetype_manual(name = "Forecasting Method",
                          values = c("Observed" = "solid", "ETS" = "dashed", "ARIMA" = "dotdash",
                                     "STL" = "longdash", "NNAR" = "twodash", "TBATS" = "dashed",
                                     "ARFIMA" = "dotted", "Prophet" = "dotdash", "RandomForest" = "twodash")) +
    scale_shape_manual(name = "Forecasting Method",
                       values = c("Observed" = NA, "ETS" = 16, "ARIMA" = 17, "STL" = 15, 
                                  "NNAR" = 18, "TBATS" = 3, "ARFIMA" = 4, "Prophet" = 8, "RandomForest" = 11)) +
    
    # 3. Etiquetas y Escalas de tiempo
    date_scale +
    labs(title = paste0("Individual Forecasts – ", asset_name),
         subtitle = "Observed values vs. individual forecasting models",
         x = "Date", y = "Price (MXN)") +
    
    # 4. Tema (Estética)
    paper_theme +
    theme(legend.position = "bottom", 
          legend.box = "horizontal") +
    
    # 5. Guías (Lógica de la leyenda) - FUERA del theme
    guides(colour = guide_legend(nrow = 2),
           linetype = guide_legend(nrow = 2),
           shape = guide_legend(nrow = 2))
  
  # ── Plot 2: ensembles vs observed ──────────────────────────
  df_ens <- bind_rows(df_obs, df_comb, df_hybrid, df_ta)

  p2 <- ggplot(df_ens, aes(x = date, y = value, colour = method)) +
    geom_line(data = subset(df_ens, method != "Observed"),
              linewidth = 1.0, alpha = 0.9) +
    geom_line(data = subset(df_ens, method == "Observed"),
              linewidth = 1.3, colour = "black") +
    date_scale +
    scale_colour_manual(name = "Method", values = COLORS) +
    labs(title    = paste0("Ensemble Forecast Comparison – ", asset_name),
         subtitle = "Black = Observed  |  Colored = Ensemble / Benchmark methods",
         x = "Date", y = "Price (MXN)") +
    paper_theme

  # ── Plot 3: TA Optimized vs Observed ───────────────────────
  p3 <- ggplot() +
    geom_line(data = df_obs, aes(x = date, y = value),
              colour = "black", linewidth = 1.2) +
    geom_line(data = df_ta,  aes(x = date, y = value),
              colour = "#d62728", linewidth = 1.1) +
    date_scale +
    labs(title    = paste0("TA Optimized Forecast – ", asset_name),
         subtitle = "Black = Observed  |  Red = TA Optimized (8 models)",
         x = "Date", y = "Price (MXN)") +
    paper_theme

  if (!is.null(save_path)) {
    ggsave(file.path(save_path, paste0(asset_name, "_individual.png")),
           p1, width = 12, height = 7, dpi = 400)
    ggsave(file.path(save_path, paste0(asset_name, "_ensembles.png")),
           p2, width = 12, height = 7, dpi = 400)
    ggsave(file.path(save_path, paste0(asset_name, "_TA_optimized.png")),
           p3, width = 11, height = 6, dpi = 400)
  }
  list(individual = p1, ensembles = p2, optimized = p3)
}

# ============================================================
# MAIN LOOP — in-sample estimation per series
# ============================================================
C_loop <- C   # change to a fixed number for testing (e.g. 4)

for (i in 2:C_loop) {

  asset <- names(datos[i])
  cat("\n=== Processing series:", asset, "===\n")

  raw_series <- as.numeric(unlist(na.approx(datos[i])))
  ts_full    <- ts(raw_series, start = c(2020, 01), frequency = 52)
  x          <- ts_full

  # ── Train / Test split (92% / 8%) ─────────────────────────
  hx             <- 0.913
  trainTestSplit <- floor(length(x) * hx)
  t_orig         <- time(ts_full)
  train <- ts(x[1:trainTestSplit],
              start = start(ts_full), frequency = frequency(x))
  test  <- ts(x[(trainTestSplit + 1):length(x)],
              start = t_orig[trainTestSplit + 1], frequency = frequency(x))

  numDatTrain <- trainTestSplit
  numDatTest  <- length(x) - numDatTrain
  h           <- numDatTest

  # ── FIT MODELS ONCE — reuse objects for pseudo-validation ──
  cat("  Fitting statistical models (single pass)...\n")

  fit_ETS   <- ets(train, model = "ANN", additive.only = FALSE,
                   biasadj = TRUE, restrict = TRUE,
                   lambda = NULL, bounds = c("both","usual","admissible"))
  ETS       <- forecast(fit_ETS, allow.multiplicative.trend = FALSE, h = h)

  fit_ARIMA <- auto.arima(train, stepwise = FALSE, approximation = TRUE)
  ARIMA     <- forecast(fit_ARIMA, h = h)

  fit_STL   <- stlf(train, lambda = NULL, h = h, biasadj = FALSE,
                    method = c("ets","arima","naive","rwdrift"))
  STL       <- fit_STL   # alias

  fit_NNAR  <- nnetar(train)
  NNAR      <- forecast(fit_NNAR, h = h)

  fit_TBATS <- tbats(train, biasadj = TRUE)
  TBATS     <- forecast(fit_TBATS, h = h)

  fit_ARFI  <- arfima(train)
  ARFIMA    <- forecast(fit_ARFI, h = h)

  HybridModel <- forecast(suppressWarnings(hybridModel(train)), h = h)

  # ── Prophet ───────────────────────────────────────────────
  cat("  Prophet...\n")
  proph_res      <- forecast_prophet(train, h)
  PROPHET_mean   <- proph_res$mean
  PROPHET_lo95   <- proph_res$lower
  PROPHET_hi95   <- proph_res$upper
  PROPHET_fitted <- proph_res$fitted

  # ── Random Forest ─────────────────────────────────────────
  cat("  Random Forest...\n")
  n_lags_rf <- min(52L, floor(numDatTrain * 0.3))
  rf_res    <- forecast_rf(train, h, n_lags = n_lags_rf)
  RF_mean   <- rf_res$mean
  RF_fitted <- rf_res$fitted

  # ── Equal-weight combination (8 models) ───────────────────
  Combination <- (ETS[["mean"]] + ARIMA[["mean"]] + STL[["mean"]] +
                    NNAR[["mean"]] + TBATS[["mean"]] + ARFIMA[["mean"]] +
                    PROPHET_mean  + RF_mean) / 8

  # ── Test-set error metrics ────────────────────────────────
  m_ETS   <- calc_m(ETS[["mean"]],    test)
  m_ARIMA <- calc_m(ARIMA[["mean"]],  test)
  m_STL   <- calc_m(STL[["mean"]],    test)
  m_NNAR  <- calc_m(NNAR[["mean"]],   test)
  m_TBATS <- calc_m(TBATS[["mean"]],  test)
  m_ARFI  <- calc_m(ARFIMA[["mean"]], test)
  m_PROPH <- calc_m(PROPHET_mean,     test)
  m_RF    <- calc_m(RF_mean,          test)
  m_Comb  <- calc_m(Combination,      test)
  m_quick <- calc_m(HybridModel[["mean"]], test)

  # ── In-sample pseudo-validation for TA ────────────────────
  # Reuse already-fitted objects — NO second training pass
  cat("  Pseudo-validation for TA (no re-fitting)...\n")
  n_pv <- max(numDatTest, max(10L, floor(numDatTrain * 0.193))) #para que se valide en 26 semanas

  pv_obs    <- safe_tail(as.numeric(train),  n_pv)
  pv_ETS    <- safe_tail(fitted(fit_ETS),    n_pv)
  pv_ARIMA  <- safe_tail(fitted(fit_ARIMA),  n_pv)
  pv_STL    <- safe_tail(fitted(fit_STL),    n_pv)
  pv_NNAR   <- safe_tail(fitted(fit_NNAR),   n_pv)
  pv_TBATS  <- safe_tail(fitted(fit_TBATS),  n_pv)
  pv_ARFIMA <- safe_tail(fitted(fit_ARFI),   n_pv)
  pv_PROPHET <- safe_tail(PROPHET_fitted,    n_pv)
  pv_RF      <- safe_tail(RF_fitted,         n_pv)

  pv_Comb  <- (pv_ETS + pv_ARIMA + pv_STL + pv_NNAR +
                 pv_TBATS + pv_ARFIMA + pv_PROPHET + pv_RF) / 8
  mse_pv   <- MSE(pv_Comb, pv_obs)
  smape_pv <- smape(pv_obs, pv_Comb)
  cat("  PV n =", n_pv, "| MSE:", round(mse_pv, 5),
      "| SMAPE:", round(smape_pv, 5), "\n")

  # ── Top-K model selection by individual PV SMAPE ─────────
  # Rank all 8 models on pseudo-validation; keep the K best.
  # Excluded models get W_MAX cap = 0, so generator() assigns
  # them exactly 0 weight — no architecture changes needed.
  MODEL_NAMES <- c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA","PROPHET","RF")
  pv_list     <- list(pv_ETS, pv_ARIMA, pv_STL, pv_NNAR,
                      pv_TBATS, pv_ARFIMA, pv_PROPHET, pv_RF)
  pv_smapes   <- sapply(pv_list, function(pv) smape(pv_obs, pv))
  names(pv_smapes) <- MODEL_NAMES

  k_use       <- min(K_MODELS, 8L)   # safety clamp
  top_k_idx   <- order(pv_smapes)[seq_len(k_use)]   # positions 1–8
  excl_idx    <- setdiff(seq_len(8L), top_k_idx)

  # Build per-asset W_MAX: 0 for excluded, original cap for selected
  W_MAX_BASE  <- c(0.45, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45)
  w_max_asset <- W_MAX_BASE
  w_max_asset[excl_idx] <- 0

  cat("  Top-", k_use, "models selected (PV SMAPE):\n")
  for (idx in top_k_idx)
    cat("    ", MODEL_NAMES[idx], ":", round(pv_smapes[idx], 5), "\n")
  if (length(excl_idx) > 0)
    cat("  Excluded:", paste(MODEL_NAMES[excl_idx], collapse=", "), "\n")

  # ── TA Optimization — 30 parallel restarts ────────────────
  T0_ta <- smape_pv * 50
  Tf_ta <- smape_pv * 0.0001
  cat("  TA Optimization (", N_CORES, "cores, 30 restarts)",
      "| T0=", round(T0_ta,6), "Tf=", round(Tf_ta,8), "...\n")

  best_sol <- run_TA_parallel(
    n_restarts = 30L, n_cores = N_CORES,
    T0 = T0_ta, Tf = Tf_ta, alfa = 0.985, gannma = 0.979, Lk = 300,
    err_pv     = smape_pv,
    pv_obs     = pv_obs,
    pv_ETS     = pv_ETS,   pv_ARIMA  = pv_ARIMA,
    pv_STL     = pv_STL,   pv_NNAR   = pv_NNAR,
    pv_TBATS   = pv_TBATS, pv_ARFIMA = pv_ARFIMA,
    pv_PROPHET = pv_PROPHET, pv_RF   = pv_RF,
    w_max      = w_max_asset
  )

  opt_weights <- best_sol[2:9]   # 8 weights
  optTA_Fcts  <- new_comb_fct(opt_weights,
                               ETS[["mean"]], ARIMA[["mean"]], STL[["mean"]],
                               NNAR[["mean"]], TBATS[["mean"]], ARFIMA[["mean"]],
                               PROPHET_mean,  RF_mean)
  m_optTA     <- calc_m(optTA_Fcts, test)

  cat("  TA Weights [ETS ARIMA STL NNAR TBATS ARFIMA PROPHET RF]:\n  ",
      round(opt_weights, 4), "\n")
  cat("  SMAPE TA:", round(m_optTA$SMAPE, 5),
      "| SMAPE EW:", round(m_Comb$SMAPE, 5), "\n")

  # ── Forecasts data frame ───────────────────────────────────
  df_forecasts <- data.frame(
    Asset       = asset,
    Date        = as.numeric(time(test)),
    Observed    = as.numeric(test),
    ETS         = as.numeric(ETS[["mean"]]),
    ARIMA       = as.numeric(ARIMA[["mean"]]),
    STL         = as.numeric(STL[["mean"]]),
    NNAR        = as.numeric(NNAR[["mean"]]),
    TBATS       = as.numeric(TBATS[["mean"]]),
    ARFIMA      = as.numeric(ARFIMA[["mean"]]),
    Prophet     = as.numeric(PROPHET_mean),
    RF          = as.numeric(RF_mean),
    Comb_EW     = as.numeric(Combination),
    HybridModel = as.numeric(HybridModel[["mean"]]),
    Comb_TA     = as.numeric(optTA_Fcts)
  )
  forecasts_global <- rbind(forecasts_global, df_forecasts)

  # ── Error metrics data frame ───────────────────────────────
  df_metrics <- data.frame(
    Asset  = asset,
    Method = c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA",
               "Prophet","RF","Comb_EW","HybridModel","Comb_TA"),
    MSE   = c(m_ETS$MSE,  m_ARIMA$MSE,  m_STL$MSE,  m_NNAR$MSE,
              m_TBATS$MSE, m_ARFI$MSE,  m_PROPH$MSE, m_RF$MSE,
              m_Comb$MSE,  m_quick$MSE, m_optTA$MSE),
    SMAPE = c(m_ETS$SMAPE, m_ARIMA$SMAPE, m_STL$SMAPE, m_NNAR$SMAPE,
              m_TBATS$SMAPE, m_ARFI$SMAPE, m_PROPH$SMAPE, m_RF$SMAPE,
              m_Comb$SMAPE,  m_quick$SMAPE, m_optTA$SMAPE),
    RMSE  = c(m_ETS$RMSE, m_ARIMA$RMSE, m_STL$RMSE, m_NNAR$RMSE,
              m_TBATS$RMSE, m_ARFI$RMSE, m_PROPH$RMSE, m_RF$RMSE,
              m_Comb$RMSE,  m_quick$RMSE, m_optTA$RMSE),
    MAPE  = c(m_ETS$MAPE, m_ARIMA$MAPE, m_STL$MAPE, m_NNAR$MAPE,
              m_TBATS$MAPE, m_ARFI$MAPE, m_PROPH$MAPE, m_RF$MAPE,
              m_Comb$MAPE,  m_quick$MAPE, m_optTA$MAPE),
    MAE   = c(m_ETS$MAE,  m_ARIMA$MAE,  m_STL$MAE,  m_NNAR$MAE,
              m_TBATS$MAE, m_ARFI$MAE,  m_PROPH$MAE, m_RF$MAE,
              m_Comb$MAE,  m_quick$MAE, m_optTA$MAE)
  )
  error_metrics <- rbind(error_metrics, df_metrics)

  # ── Generate and save plots ────────────────────────────────
  fcts_list <- list(
    ETS          = ETS,       ARIMA        = ARIMA,
    STL          = STL,       NNAR         = NNAR,
    TBATS        = TBATS,     ARFIMA       = ARFIMA,
    PROPHET_mean = PROPHET_mean, RF_mean   = RF_mean,
    Combination  = Combination, HybridModel = HybridModel,
    optTA_Fcts   = optTA_Fcts
  )
  plots <- create_plots(asset, test, fcts_list, save_path = graf_path)
  print(plots$ensembles)

  # ── Best weights row ───────────────────────────────────────
  best_row <- data.frame(
    ASSET   = asset, SMAPE  = best_sol[1],
    ETS     = opt_weights[1], ARIMA   = opt_weights[2],
    STL     = opt_weights[3], NNAR    = opt_weights[4],
    TBATS   = opt_weights[5], ARFIMA  = opt_weights[6],
    PROPHET = opt_weights[7], RF      = opt_weights[8]
  )
  memoriaBest_global <- rbind(memoriaBest_global, best_row)

  # ── Series information data frame ─────────────────────────
  info_row <- data.frame(
    Asset             = asset,
    Total_Length      = length(x),
    Train_Length      = numDatTrain,
    Test_Length       = numDatTest,
    K_Selected        = k_use,
    Models_Selected   = paste(MODEL_NAMES[top_k_idx], collapse = ", "),
    Models_Excluded   = paste(MODEL_NAMES[excl_idx],  collapse = ", "),
    SMAPE_ETS         = m_ETS$SMAPE,
    SMAPE_ARIMA       = m_ARIMA$SMAPE,
    SMAPE_Prophet     = m_PROPH$SMAPE,
    SMAPE_RF          = m_RF$SMAPE,
    SMAPE_Comb_EW     = m_Comb$SMAPE,
    SMAPE_HybridModel = m_quick$SMAPE,
    SMAPE_TA          = m_optTA$SMAPE,
    Improvement_TA_vs_EW = ((m_Comb$SMAPE - m_optTA$SMAPE) / m_Comb$SMAPE) * 100,
    TA_Weights        = paste(round(opt_weights, 4), collapse = ", ")
  )
  series_info <- rbind(series_info, info_row)

  cat("Completed:", asset, "\n")
}

# ============================================================
# SAVE IN-SAMPLE RESULTS
# ============================================================
time_end <- Sys.time()
cat("\nTotal time (in-sample):",
    round(difftime(time_end, time_start, units = "mins"), 2), "min\n")

write.csv(forecasts_global,
          file.path(base_path, "forecasts_complete_v5.csv"),   row.names = FALSE)
write.csv(error_metrics,
          file.path(base_path, "error_metrics_v5.csv"),        row.names = FALSE)
write.csv(series_info,
          file.path(base_path, "series_information_v5.csv"),   row.names = FALSE)
write.csv(memoriaBest_global,
          file.path(base_path, "TA_best_weights_v5.csv"),      row.names = FALSE)

# ============================================================
# SUMMARY TABLE AND BOXPLOT
# ============================================================
cat("\n=== FINAL SUMMARY ===\n")
summary_metrics <- error_metrics %>%
  group_by(Method) %>%
  summarise(
    MSE_Mean   = mean(MSE,   na.rm = TRUE),
    SMAPE_Mean = mean(SMAPE, na.rm = TRUE),
    RMSE_Mean  = mean(RMSE,  na.rm = TRUE),
    MAE_Mean   = mean(MAE,   na.rm = TRUE),
    .groups    = "drop"
  ) %>%
  arrange(SMAPE_Mean)

print(summary_metrics)

box_order <- summary_metrics$Method

palette_box <- c(
  "ETS"         = "#4e9a8f", "ARIMA"       = "#e07b39",
  "STL"         = "#7b68b5", "NNAR"        = "#d45d8a",
  "TBATS"       = "#6aaa3a", "ARFIMA"      = "#d4aa00",
  "Prophet"     = "#17becf", "RF"          = "#8c564b",
  "Comb_EW"     = "#2171b5", "HybridModel" = "#41ab5d",
  "Comb_TA"     = "#cb181d"
)[box_order]

df_box <- error_metrics %>%
  mutate(Method = factor(Method, levels = box_order),
         Group  = ifelse(Method %in% c("Comb_EW","Comb_TA"), "Ensemble",
                  ifelse(Method == "HybridModel",             "Benchmark",
                  ifelse(Method %in% c("Prophet","RF"),       "ML/Bayesian",
                                                              "Statistical"))))

p_box <- ggplot(df_box, aes(x = Method, y = SMAPE, fill = Method)) +
  geom_boxplot(outlier.shape = NA, width = 0.55, alpha = 0.82,
               colour = "grey25", linewidth = 0.55) +
  geom_jitter(aes(colour = Method), width = 0.18, size = 1.8,
              alpha = 0.55, shape = 16) +
  stat_summary(fun = mean,   geom = "point", shape = 23, size = 4,
               fill = "white", colour = "grey20", stroke = 1.1) +
  stat_summary(fun = median, geom = "crossbar", width = 0.55,
               linewidth = 0.8, colour = "grey10", fatten = 0) +
  #geom_vline(xintercept = c(6.5, 8.5),
             #linetype = "dashed", colour = "grey50", linewidth = 0.6) +
  scale_fill_manual(values   = palette_box) +
  scale_colour_manual(values = palette_box) +
  theme_classic(base_size = 13) +
  theme(axis.text.x       = element_text(angle = 35, hjust = 1, size = 11),
        plot.title         = element_text(face = "bold", hjust = 0.5, size = 15),
        plot.subtitle      = element_text(hjust = 0.5, size = 10, colour = "grey40"),
        legend.position    = "none",
        panel.grid.major.y = element_line(color = "grey88", linewidth = 0.4),
        plot.margin        = margin(10, 15, 10, 10)) +
  labs(title    = "SMAPE Distribution per Forecast Method (8 base models + benchmark)",
       subtitle  = "◆ = mean  |  ─ = median  |  dots = individual assets",
       x = "Forecast Method", y = "SMAPE")

ggsave(file.path(graf_path, "boxplot_SMAPE_v5.png"),
       p_box, width = 14, height = 7.5, dpi = 400)
print(p_box)
cat("\n✔ In-sample phase completed. Files saved in:", base_path, "\n")




# ============================================================
#  DIEBOLD-MARIANO (DM) AND HARVEY-LEYBOURNE-NEWBOLD (HLN) TESTS
#  Pairwise comparison of all forecast methods
#  Computed per asset, then averaged across assets
#  Output: results .txt  +  4 heatmaps (.png)
#  Requires: forecasts_global (built in the main loop)
# ============================================================

if (!requireNamespace("viridis", quietly = TRUE)) install.packages("viridis")
library(scales)
library(viridis)

cat("\n============================================================\n")
cat(" DIEBOLD-MARIANO (DM) AND HLN TESTS\n")
cat("============================================================\n")

# ── Methods — exact column names in forecasts_global ─────────
METHODS <- c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA",
             "Prophet","RF","Comb_EW","HybridModel","Comb_TA")
nM <- length(METHODS)

# ── HLN test function (Harvey, Leybourne & Newbold, 1997) ────
# Corrects DM statistic for small samples.
# e1, e2: forecast error vectors; h: forecast horizon
# Returns: list(statistic, p.value) using t(n-1) distribution
hln_test <- function(e1, e2, h = 1) {
  d     <- e1^2 - e2^2        # quadratic loss differential
  n     <- length(d)
  if (n < 3) return(list(statistic = NA_real_, p.value = NA_real_))
  d_bar  <- mean(d)
  gamma0 <- var(d)
  gamma  <- 0
  if (h > 1) {
    for (k in 1:(h - 1)) {
      gk    <- cov(d[(k + 1):n], d[1:(n - k)])
      gamma <- gamma + 2 * (1 - k / h) * gk
    }
  }
  var_d <- (gamma0 + gamma) / n
  if (var_d <= 0) return(list(statistic = NA_real_, p.value = NA_real_))
  DM_stat  <- d_bar / sqrt(var_d)
  cf       <- sqrt((n + 1 - 2 * h + h * (h - 1) / n) / n)
  HLN_stat <- DM_stat * cf
  pval     <- 2 * pt(-abs(HLN_stat), df = n - 1)
  list(statistic = HLN_stat, p.value = pval)
}

# ── Significance stars helper ─────────────────────────────────
sig_stars <- function(p) {
  ifelse(is.na(p), "   ",
         ifelse(p < 0.001, "***",
                ifelse(p < 0.01,  "** ",
                       ifelse(p < 0.05,  "*  ", "   "))))
}

# ── Accumulator matrices (nM × nM) ───────────────────────────
assets_unique  <- unique(forecasts_global$Asset)
nA             <- length(assets_unique)

acum_DM_stat   <- matrix(0, nM, nM, dimnames = list(METHODS, METHODS))
acum_DM_pval   <- matrix(0, nM, nM, dimnames = list(METHODS, METHODS))
acum_HLN_stat  <- matrix(0, nM, nM, dimnames = list(METHODS, METHODS))
acum_HLN_pval  <- matrix(0, nM, nM, dimnames = list(METHODS, METHODS))
count_valid    <- matrix(0, nM, nM, dimnames = list(METHODS, METHODS))

cat("\nRunning pairwise tests per asset...\n")

for (ast in assets_unique) {

  sub <- forecasts_global[forecasts_global$Asset == ast, ]
  obs <- sub$Observed
  n   <- nrow(sub)

  for (ii in 1:nM) {
    for (jj in 1:nM) {
      if (ii == jj) next

      pred_i <- sub[[METHODS[ii]]]
      pred_j <- sub[[METHODS[jj]]]
      e_i    <- obs - pred_i
      e_j    <- obs - pred_j

      # ── DM test ───────────────────────────────────────────
      dm_res <- tryCatch(
        dm.test(e_i, e_j, alternative = "two.sided", h = 1, power = 2),
        error = function(e) NULL
      )

      # ── HLN test ──────────────────────────────────────────
      hln_res <- tryCatch(
        hln_test(e_i, e_j, h = 1),
        error = function(e) list(statistic = NA_real_, p.value = NA_real_)
      )

      if (!is.null(dm_res) && !is.na(dm_res$p.value)) {
        acum_DM_stat[ii, jj] <- acum_DM_stat[ii, jj] + dm_res$statistic
        acum_DM_pval[ii, jj] <- acum_DM_pval[ii, jj] + dm_res$p.value
        count_valid[ii, jj]  <- count_valid[ii, jj]  + 1
      }
      if (!is.na(hln_res$p.value)) {
        acum_HLN_stat[ii, jj] <- acum_HLN_stat[ii, jj] + hln_res$statistic
        acum_HLN_pval[ii, jj] <- acum_HLN_pval[ii, jj] + hln_res$p.value
      }
    }
  }
  cat("  ✔", ast, "\n")
}

# ── Average across assets ─────────────────────────────────────
cv          <- count_valid
cv[cv == 0] <- NA

mat_DM_stat  <- acum_DM_stat  / cv
mat_DM_pval  <- acum_DM_pval  / cv
mat_HLN_stat <- acum_HLN_stat / cv
mat_HLN_pval <- acum_HLN_pval / cv

diag(mat_DM_stat)  <- NA
diag(mat_DM_pval)  <- NA
diag(mat_HLN_stat) <- NA
diag(mat_HLN_pval) <- NA

# ── Win/loss score table ──────────────────────────────────────
wins   <- sapply(1:nM, function(ii)
  sum(mat_DM_stat[ii, ] < 0 & mat_DM_pval[ii, ] < 0.05, na.rm = TRUE))
losses <- sapply(1:nM, function(ii)
  sum(mat_DM_stat[ii, ] > 0 & mat_DM_pval[ii, ] < 0.05, na.rm = TRUE))
df_score <- data.frame(
  Method = METHODS, Wins = wins, Losses = losses,
  Net    = wins - losses
)
df_score <- df_score[order(-df_score$Net), ]

# ============================================================
#  TEXT OUTPUT FILE
# ============================================================
dm_txt_path <- file.path(base_path, "DM_HLN_results_v5.1.txt")
sink(dm_txt_path)

cat("================================================================\n")
cat("  DIEBOLD-MARIANO (DM) AND HARVEY-LEYBOURNE-NEWBOLD (HLN) TESTS\n")
cat("  Averaged over", nA, "time series\n")
cat("  Loss function: Quadratic  |  Horizon h=1  |  Two-sided\n")
cat("================================================================\n\n")

cat("INTERPRETATION:\n")
cat("  DM / HLN statistic < 0  → row method outperforms column method\n")
cat("  DM / HLN statistic > 0  → column method outperforms row method\n")
cat("  p < 0.05  → statistically significant difference (*)\n")
cat("  p < 0.01  → highly significant (**)\n")
cat("  p < 0.001 → very highly significant (***)\n\n")

cat("----------------------------------------------------------------\n")
cat("TABLE 1 — Average DM statistic  (row vs column)\n")
cat("----------------------------------------------------------------\n")
print(round(mat_DM_stat, 4), na.print = "  — ")

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 2 — Average DM p-values\n")
cat("----------------------------------------------------------------\n")
print(round(mat_DM_pval, 4), na.print = "  — ")

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 3 — Average HLN statistic  (small-sample correction)\n")
cat("----------------------------------------------------------------\n")
print(round(mat_HLN_stat, 4), na.print = "  — ")

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 4 — Average HLN p-values\n")
cat("----------------------------------------------------------------\n")
print(round(mat_HLN_pval, 4), na.print = "  — ")

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 5 — DM significance  (* p<.05  ** p<.01  *** p<.001)\n")
cat("----------------------------------------------------------------\n")
sig_mat_dm <- matrix(
  paste0(sprintf("%7.4f", round(mat_DM_pval, 4)), sig_stars(mat_DM_pval)),
  nrow = nM, dimnames = list(METHODS, METHODS))
diag(sig_mat_dm) <- "   —   "
print(sig_mat_dm, quote = FALSE)

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 6 — HLN significance  (* p<.05  ** p<.01  *** p<.001)\n")
cat("----------------------------------------------------------------\n")
sig_mat_hln <- matrix(
  paste0(sprintf("%7.4f", round(mat_HLN_pval, 4)), sig_stars(mat_HLN_pval)),
  nrow = nM, dimnames = list(METHODS, METHODS))
diag(sig_mat_hln) <- "   —   "
print(sig_mat_hln, quote = FALSE)

cat("\n\n")
cat("----------------------------------------------------------------\n")
cat("TABLE 7 — Significant win count per method (DM, p < 0.05)\n")
cat("  'row beats column' when statistic < 0 AND p < 0.05\n")
cat("----------------------------------------------------------------\n")
print(df_score, row.names = FALSE)

cat("\n\n================================================================\n")
cat("  Output files:\n")
cat("  • DM_HLN_results_v5.1.txt\n")
cat("  • heatmap_DM_pval_v5.1.png\n")
cat("  • heatmap_HLN_pval_v5.1.png\n")
cat("  • heatmap_DM_stat_v5.1.png\n")
cat("  • heatmap_DM_superiority_v5.1.png\n")
cat("================================================================\n")
sink()
cat("✔ DM/HLN text results saved:", dm_txt_path, "\n")

# ============================================================
#  HEATMAPS
# ============================================================

# ── Heatmap 1: DM p-values ───────────────────────────────────
df_dm_pval <- reshape2::melt(mat_DM_pval, na.rm = FALSE)
colnames(df_dm_pval) <- c("Row","Column","Pval")
df_dm_pval$Row    <- factor(df_dm_pval$Row,    levels = rev(METHODS))
df_dm_pval$Column <- factor(df_dm_pval$Column, levels = METHODS)
df_dm_pval$label  <- ifelse(is.na(df_dm_pval$Pval), "—",
                             paste0(sprintf("%.3f", df_dm_pval$Pval),
                                    "\n", trimws(sig_stars(df_dm_pval$Pval))))

p_dm_pval <- ggplot(df_dm_pval, aes(x = Column, y = Row, fill = Pval)) +
  geom_tile(colour = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 2.75, lineheight = 0.85, colour = "grey10") +
  scale_fill_gradientn(
    colours  = c("#b2182b","#ef8a62","#fddbc7","#f7f7f7","#d1e5f0"),
    values   = rescale(c(0, 0.01, 0.05, 0.10, 1)),
    limits   = c(0, 1), name = "p-value", na.value = "grey85",
    guide    = guide_colorbar(barwidth = 1, barheight = 10)) +
  scale_x_discrete(position = "top") +
  labs(title    = "Diebold-Mariano Test — p-values (averaged across assets)",
       subtitle  = paste0("H₀: equal predictive accuracy  |  Quadratic loss  |  Two-sided  |  n = ",
                          nA, " series\nDeep red = significant difference"),
       x = NULL, y = NULL) +
  theme_minimal(base_size = 12) +
  theme(plot.title      = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle   = element_text(hjust = 0.5, size = 9.5, colour = "grey40"),
        axis.text.x     = element_text(angle = 40, hjust = 0, size = 10, face = "bold"),
        axis.text.y     = element_text(size = 10, face = "bold"),
        panel.grid      = element_blank(),
        legend.position = "right",
        plot.margin     = margin(12, 12, 12, 12))

ggsave(file.path(base_path, "heatmap_DM_pval_v5.1.png"),
       p_dm_pval, width = 13, height = 10, dpi = 400)
print(p_dm_pval)
cat("✔ DM p-value heatmap saved.\n")

# ── Heatmap 2: HLN p-values ──────────────────────────────────
df_hln_pval <- reshape2::melt(mat_HLN_pval, na.rm = FALSE)
colnames(df_hln_pval) <- c("Row","Column","Pval")
df_hln_pval$Row    <- factor(df_hln_pval$Row,    levels = rev(METHODS))
df_hln_pval$Column <- factor(df_hln_pval$Column, levels = METHODS)
df_hln_pval$label  <- ifelse(is.na(df_hln_pval$Pval), "—",
                              paste0(sprintf("%.3f", df_hln_pval$Pval),
                                     "\n", trimws(sig_stars(df_hln_pval$Pval))))

p_hln_pval <- ggplot(df_hln_pval, aes(x = Column, y = Row, fill = Pval)) +
  geom_tile(colour = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 2.75, lineheight = 0.85, colour = "grey10") +
  scale_fill_gradientn(
    colours  = c("#b2182b","#ef8a62","#fddbc7","#f7f7f7","#d1e5f0"),
    values   = rescale(c(0, 0.01, 0.05, 0.10, 1)),
    limits   = c(0, 1), name = "p-value", na.value = "grey85",
    guide    = guide_colorbar(barwidth = 1, barheight = 10)) +
  scale_x_discrete(position = "top") +
  labs(title    = "Harvey-Leybourne-Newbold (HLN) Test — p-values (averaged across assets)",
       subtitle  = paste0("Small-sample correction on DM  |  t(T-1)  |  Two-sided  |  n = ",
                          nA, " series\nDeep red = significant difference"),
       x = NULL, y = NULL) +
  theme_minimal(base_size = 12) +
  theme(plot.title      = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle   = element_text(hjust = 0.5, size = 9.5, colour = "grey40"),
        axis.text.x     = element_text(angle = 40, hjust = 0, size = 10, face = "bold"),
        axis.text.y     = element_text(size = 10, face = "bold"),
        panel.grid      = element_blank(),
        legend.position = "right",
        plot.margin     = margin(12, 12, 12, 12))

ggsave(file.path(base_path, "heatmap_HLN_pval_v5.1.png"),
       p_hln_pval, width = 13, height = 10, dpi = 400)
print(p_hln_pval)
cat("✔ HLN p-value heatmap saved.\n")

# ── Heatmap 3: DM statistic (direction of superiority) ───────
df_dm_stat <- reshape2::melt(mat_DM_stat, na.rm = FALSE)
colnames(df_dm_stat) <- c("Row","Column","Stat")
df_dm_stat$Row    <- factor(df_dm_stat$Row,    levels = rev(METHODS))
df_dm_stat$Column <- factor(df_dm_stat$Column, levels = METHODS)

df_pval_long <- reshape2::melt(mat_DM_pval, na.rm = FALSE)
colnames(df_pval_long) <- c("Row","Column","Pval")
df_pval_long$Row    <- factor(df_pval_long$Row,    levels = rev(METHODS))
df_pval_long$Column <- factor(df_pval_long$Column, levels = METHODS)
df_dm_stat <- merge(df_dm_stat, df_pval_long, by = c("Row","Column"))
df_dm_stat$label <- ifelse(
  is.na(df_dm_stat$Stat), "—",
  paste0(sprintf("%.2f", df_dm_stat$Stat),
         "\n", trimws(sig_stars(df_dm_stat$Pval))))

lim_s <- max(abs(mat_DM_stat), na.rm = TRUE) * 1.05

p_dm_stat <- ggplot(df_dm_stat, aes(x = Column, y = Row, fill = Stat)) +
  geom_tile(colour = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 2.75, lineheight = 0.85, colour = "grey10") +
  scale_fill_gradientn(
    colours  = c("#2166ac","#92c5de","#f7f7f7","#f4a582","#d6604d"),
    values   = rescale(c(-lim_s, -1, 0, 1, lim_s)),
    limits   = c(-lim_s, lim_s),
    name     = "DM\nstatistic", na.value = "grey85",
    guide    = guide_colorbar(barwidth = 1, barheight = 10)) +
  scale_x_discrete(position = "top") +
  labs(title    = "DM Statistic — Direction of Superiority",
       subtitle  = paste0("Blue: row outperforms column  |  Red: column outperforms row  |  n = ",
                          nA, " series\nSignificance: * p<.05  ** p<.01  *** p<.001"),
       x = NULL, y = NULL) +
  theme_minimal(base_size = 12) +
  theme(plot.title      = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle   = element_text(hjust = 0.5, size = 9.5, colour = "grey40"),
        axis.text.x     = element_text(angle = 40, hjust = 0, size = 10, face = "bold"),
        axis.text.y     = element_text(size = 10, face = "bold"),
        panel.grid      = element_blank(),
        legend.position = "right",
        plot.margin     = margin(12, 12, 12, 12))

ggsave(file.path(base_path, "heatmap_DM_stat_v5.1.png"),
       p_dm_stat, width = 13, height = 10, dpi = 400)
print(p_dm_stat)
cat("✔ DM statistic heatmap saved.\n")

# ── Heatmap 4: Net win scoreboard ────────────────────────────
win_mat <- matrix(NA_real_, nM, nM, dimnames = list(METHODS, METHODS))
for (ii in 1:nM) for (jj in 1:nM) {
  if (ii == jj) next
  s <- mat_DM_stat[ii, jj]; p <- mat_DM_pval[ii, jj]
  if (is.na(s) || is.na(p)) next
  win_mat[ii, jj] <- ifelse(s < 0 & p < 0.05,  1,
                     ifelse(s > 0 & p < 0.05, -1, 0))
}

df_win <- reshape2::melt(win_mat, na.rm = FALSE)
colnames(df_win) <- c("Row","Column","Result")
df_win$Row    <- factor(df_win$Row,    levels = rev(METHODS))
df_win$Column <- factor(df_win$Column, levels = METHODS)
df_win$label  <- ifelse(is.na(df_win$Result), "—",
                 ifelse(df_win$Result ==  1, "Better",
                 ifelse(df_win$Result == -1, "Worse", "=")))

p_win <- ggplot(df_win, aes(x = Column, y = Row, fill = Result)) +
  geom_tile(colour = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 3.0, fontface = "bold", colour = "grey10") +
  scale_fill_gradientn(
    colours  = c("#d73027","#fee08b","#f7f7f7","#a6d96a","#1a9641"),
    values   = rescale(c(-1, -0.5, 0, 0.5, 1)),
    limits   = c(-1, 1), breaks = c(-1, 0, 1),
    labels   = c("Worse","Tie","Better"),
    name     = "Result\n(p<0.05)", na.value = "grey85") +
  scale_x_discrete(position = "top") +
  labs(title    = "Pairwise Significant Superiority — DM Test (p < 0.05)",
       subtitle  = paste0("Green: row significantly better than column  |  Red: row worse  |  n = ",
                          nA, " series"),
       x = NULL, y = NULL) +
  theme_minimal(base_size = 12) +
  theme(plot.title      = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle   = element_text(hjust = 0.5, size = 9.5, colour = "grey40"),
        axis.text.x     = element_text(angle = 40, hjust = 0, size = 10, face = "bold"),
        axis.text.y     = element_text(size = 10, face = "bold"),
        panel.grid      = element_blank(),
        legend.position = "right",
        plot.margin     = margin(12, 12, 12, 12))

ggsave(file.path(base_path, "heatmap_DM_superiority_v5.1.png"),
       p_win, width = 13, height = 10, dpi = 400)
print(p_win)
cat("✔ DM superiority heatmap saved.\n")

# ── Console summary ───────────────────────────────────────────
cat("\n=== DM/HLN SUMMARY — Net win ranking (DM, p<0.05) ===\n")
print(df_score, row.names = FALSE)
cat("\n✔ DM/HLN tests completed.\n")


# ============================================================
#  OOS BLOCK — OUT-OF-SAMPLE FORECASTS
#  Trains on the COMPLETE series and forecasts H_OOS steps
#  ahead.  TA weights are those already optimized in-sample.
#  Call compare_oos() when actual future data become available.
# ============================================================
cat("\n============================================================\n")
cat(" OUT-OF-SAMPLE FORECASTS (H =", H_OOS, "weeks)\n")
cat("============================================================\n")

time_oos_start <- Sys.time()

for (i in 2:C_loop) {
  
  asset <- names(datos[i])
  cat("\n  OOS — series:", asset, "\n")
  
  # ── Full series ────────────────────────────────────────────
  raw_series <- as.numeric(unlist(na.approx(datos[i])))
  full_ts    <- ts(raw_series, start = c(2020, 01), frequency = 52)
  h_oos      <- H_OOS
  
  # ── Retrieve optimized TA weights ─────────────────────────
  idx_w <- which(memoriaBest_global$ASSET == asset)
  if (length(idx_w) == 0) {
    cat("    ⚠ No TA weights found for", asset, "— using equal weights\n")
    weights_oos <- rep(1/8, 8)
  } else {
    sub_w       <- memoriaBest_global[idx_w, ]
    sub_w       <- sub_w[order(as.numeric(sub_w$SMAPE)), ]
    weights_oos <- as.numeric(sub_w[1, c("ETS","ARIMA","STL","NNAR",
                                         "TBATS","ARFIMA","PROPHET","RF")])
  }

  # ── OOS shrinkage toward equal weights (LAMBDA parameter) ─
  # Pure TA weights are kept in weights_oos (for Comb_TA column).
  # Shrunk weights are stored in weights_oos_shrunk (for Comb_TA_Shrunk).
  # Active models = those with non-zero TA weight.
  active_oos       <- which(weights_oos > 0)
  n_active_oos     <- max(length(active_oos), 1L)
  w_equal_oos      <- rep(0, 8L)
  w_equal_oos[active_oos] <- 1 / n_active_oos
  weights_oos_shrunk <- LAMBDA * weights_oos + (1 - LAMBDA) * w_equal_oos
  weights_oos_shrunk <- weights_oos_shrunk / sum(weights_oos_shrunk)
  cat("    Shrinkage λ =", LAMBDA,
      "| Active models:", n_active_oos, "\n")
  
  # ── Fit all models on the COMPLETE series ─────────────────
  cat("    Fitting OOS models on full series...\n")
  
  oos_ETS <- forecast(
    ets(full_ts, model = "ANN", additive.only = FALSE, biasadj = TRUE,
        restrict = TRUE, lambda = NULL, bounds = c("both","usual","admissible")),
    allow.multiplicative.trend = FALSE, h = h_oos)
  
  oos_ARIMA <- forecast(
    auto.arima(full_ts, stepwise = FALSE, approximation = TRUE), h = h_oos)
  
  oos_STL <- stlf(full_ts, lambda = NULL, h = h_oos, biasadj = FALSE,
                  method = c("ets","arima","naive","rwdrift"))
  
  oos_NNAR  <- forecast(nnetar(full_ts),           h = h_oos)
  oos_TBATS <- forecast(tbats(full_ts, biasadj = TRUE), h = h_oos)
  oos_ARFIMA <- forecast(arfima(full_ts),          h = h_oos)
  oos_HYBRID <- forecast(suppressWarnings(hybridModel(full_ts)), h = h_oos)
  
  cat("    Prophet OOS...\n")
  oos_proph   <- forecast_prophet(full_ts, h_oos)
  oos_PROPHET <- oos_proph$mean
  
  cat("    Random Forest OOS...\n")
  n_lags_oos <- min(52L, floor(length(full_ts) * 0.3))
  oos_rf     <- forecast_rf(full_ts, h_oos, n_lags = n_lags_oos)
  oos_RF     <- oos_rf$mean
  
  # ── Combinations ──────────────────────────────────────────
  oos_EW <- (oos_ETS[["mean"]] + oos_ARIMA[["mean"]] + oos_STL[["mean"]] +
               oos_NNAR[["mean"]] + oos_TBATS[["mean"]] + oos_ARFIMA[["mean"]] +
               oos_PROPHET + oos_RF) / 8
  
  # Pure TA weights (used for Comb_TA — unchanged from IS optimization)
  oos_TA <- new_comb_fct(weights_oos,
                         oos_ETS[["mean"]], oos_ARIMA[["mean"]], oos_STL[["mean"]],
                         oos_NNAR[["mean"]], oos_TBATS[["mean"]], oos_ARFIMA[["mean"]],
                         oos_PROPHET, oos_RF)

  # Shrunk weights (robustness ensemble — only computed for OOS)
  oos_TA_shrunk <- new_comb_fct(weights_oos_shrunk,
                                oos_ETS[["mean"]], oos_ARIMA[["mean"]], oos_STL[["mean"]],
                                oos_NNAR[["mean"]], oos_TBATS[["mean"]], oos_ARFIMA[["mean"]],
                                oos_PROPHET, oos_RF)
  
  # ── Future dates — anchored to last real date in datos CSV ──
  # Avoids decimal-year drift from ts time() arithmetic.
  # datos[,1] is the Date column; last row = last known observation.
  # With datos ending 2025-08-31 and h=26 this produces:
  #   future_dates[1]  = 2025-09-07  (matches OOS actual CSV start)
  #   future_dates[26] = 2026-03-01  (matches OOS actual CSV end)
  last_real_date <- as.Date(tail(datos[, 1], 1))
  future_dates   <- last_real_date + 7L * seq_len(h_oos)
  future_t       <- as.numeric(future_dates)   # kept for compatibility
  
  # ── OOS data frame ────────────────────────────────────────
  df_oos <- data.frame(
    Asset       = asset,
    Date_Num    = future_t,
    Date        = future_dates,
    Actual      = NA_real_,          # filled by compare_oos() when data arrive
    ETS         = as.numeric(oos_ETS[["mean"]]),
    ARIMA       = as.numeric(oos_ARIMA[["mean"]]),
    STL         = as.numeric(oos_STL[["mean"]]),
    NNAR        = as.numeric(oos_NNAR[["mean"]]),
    TBATS       = as.numeric(oos_TBATS[["mean"]]),
    ARFIMA      = as.numeric(oos_ARFIMA[["mean"]]),
    Prophet     = as.numeric(oos_PROPHET),
    RF          = as.numeric(oos_RF),
    Comb_EW        = as.numeric(oos_EW),
    HybridModel    = as.numeric(oos_HYBRID[["mean"]]),
    Comb_TA        = as.numeric(oos_TA),
    Comb_TA_Shrunk = as.numeric(oos_TA_shrunk)   # shrinkage λ applied
  )
  forecasts_oos <- rbind(forecasts_oos, df_oos)
  cat("    ✔", asset, "— OOS generated for", h_oos, "weeks ahead\n")
}

time_oos_end <- Sys.time()
cat("\nOOS total time:",
    round(difftime(time_oos_end, time_oos_start, units = "mins"), 2), "min\n")

write.csv(forecasts_oos,
          file.path(base_path, "forecasts_OOS_v5.csv"), row.names = FALSE)
cat("✔ forecasts_OOS_v5.csv saved.\n")

# ============================================================
#  compare_oos()
#  When actual OOS data become available, load a CSV with
#  columns [Date, <asset1>, <asset2>, ...] and call:
#
#    result <- compare_oos(forecasts_oos, actual_data)
#
#  Returns: updated OOS df (Actual column filled) +
#           metrics table by asset and method.
# ============================================================
compare_oos <- function(df_oos, actual_data,
                        date_col_oos    = "Date",
                        date_col_actual = "Date") {
  
  actual_data[[date_col_actual]] <- as.Date(actual_data[[date_col_actual]])
  df_oos[[date_col_oos]]         <- as.Date(df_oos[[date_col_oos]])
  
  assets       <- unique(df_oos$Asset)
  metrics_oos  <- data.frame()
  
  for (ast in assets) {
    sub_oos <- df_oos[df_oos$Asset == ast, ]
    
    if (!(ast %in% colnames(actual_data))) {
      cat("  ⚠ No column found for asset:", ast, "\n")
      next
    }
    
    # Match by date
    merged <- merge(sub_oos,
                    actual_data[, c(date_col_actual, ast)],
                    by.x = date_col_oos, by.y = date_col_actual,
                    all.x = TRUE)
    colnames(merged)[colnames(merged) == ast] <- "Actual_tmp"
    merged$Actual     <- merged$Actual_tmp
    merged$Actual_tmp <- NULL
    
    # Update Actual column in df_oos
    df_oos[df_oos$Asset == ast, "Actual"] <- merged$Actual
    
    # Compute metrics only where actuals exist
    sub_valid <- merged[!is.na(merged$Actual), ]
    if (nrow(sub_valid) == 0) {
      cat("  ⚠ No actual observations available for:", ast, "\n")
      next
    }
    
    OOS_METHODS <- c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA",
                     "Prophet","RF","Comb_EW","HybridModel","Comb_TA",
                     "Comb_TA_Shrunk")
    
    for (met in OOS_METHODS) {
      if (!(met %in% colnames(sub_valid))) next
      pred_v <- sub_valid[[met]]
      obs_v  <- sub_valid$Actual
      ok     <- !is.na(pred_v) & !is.na(obs_v)
      if (sum(ok) == 0) next
      
      m_oos <- calc_m(pred_v[ok], obs_v[ok])
      
      metrics_oos <- rbind(metrics_oos, data.frame(
        Asset  = ast,
        Method = met,
        N      = sum(ok),
        MSE    = m_oos$MSE,
        RMSE   = m_oos$RMSE,
        MAE    = m_oos$MAE,
        MAPE   = m_oos$MAPE,
        SMAPE  = m_oos$SMAPE
      ))
    }
    cat("  ✔ OOS metrics computed for:", ast, "\n")
  }
  
  list(forecasts_oos_updated = df_oos,
       metrics_oos            = metrics_oos)
}

# ── Automatic OOS comparison if actual data was loaded ────────
if (!is.null(actual_oos_data)) {
  cat("\n============================================================\n")
  cat(" OOS COMPARISON — forecasts vs. actual data\n")
  cat("============================================================\n")
  
  oos_result    <- compare_oos(forecasts_oos, actual_oos_data)
  forecasts_oos <- oos_result$forecasts_oos_updated   # Actual column now filled
  metrics_oos   <- oos_result$metrics_oos
  
  write.csv(metrics_oos,
            file.path(base_path, "metrics_OOS_v5.1.csv"), row.names = FALSE)
  cat("✔ OOS error metrics saved: metrics_OOS_v5.1.csv\n")
  
  # ── Print OOS metric summary by asset ──────────────────────
  cat("\n--- OOS SMAPE by method (averaged across assets) ---\n")
  methods_oos <- c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA",
                   "Prophet","RF","Comb_EW","HybridModel","Comb_TA",
                   "Comb_TA_Shrunk")
  smape_means <- sapply(methods_oos, function(m) {
    sub <- metrics_oos[metrics_oos$Method == m, ]
    if (nrow(sub) == 0) return(NA_real_)
    mean(sub$SMAPE, na.rm = TRUE)
  })
  df_oos_summary <- data.frame(Method     = names(smape_means),
                               Mean_SMAPE = round(smape_means, 5))
  df_oos_summary <- df_oos_summary[order(df_oos_summary$Mean_SMAPE), ]
  print(df_oos_summary, row.names = FALSE)
} else {
  metrics_oos <- NULL
  cat("\n⚠ No actual OOS data available — skipping OOS comparison.\n")
  cat("  Set oos_actual_path at the top of the script to enable it.\n")
}

# ============================================================
#  OOS CHART — forecasts vs. recent historical window
# ============================================================
# ============================================================
#  create_oos_plot — FIXED DATE ALIGNMENT
#
#  ROOT CAUSE of previous bug:
#    hist_dates was derived from time(full_ts) → date_decimal(),
#    which introduces rounding drift and does NOT guarantee
#    alignment with the actual calendar dates in datos.
#
#  FIX:
#    Historical window is built directly from the `datos` Date
#    column, anchored to the FIRST date in df_oos_asset$Date.
#    No ts / decimal-year conversion is needed.
# ============================================================
# ── Helper: build historical + actual OOS data frames ────────
# Shared by both OOS plot functions.
.oos_base_data <- function(asset_name, datos_df, df_oos_asset, n_hist) {
  oos_dates      <- as.Date(df_oos_asset$Date)
  first_oos      <- min(oos_dates)
  last_oos       <- max(oos_dates)
  datos_dates    <- as.Date(datos_df[, 1])
  datos_prices   <- as.numeric(datos_df[[asset_name]])
  mask_hist      <- datos_dates < first_oos & !is.na(datos_prices)
  hall           <- datos_dates[mask_hist]
  vall           <- datos_prices[mask_hist]
  n_avail        <- length(hall)
  idx_from       <- max(1L, n_avail - n_hist + 1L)
  df_hist <- data.frame(date  = hall[idx_from:n_avail],
                        value = vall[idx_from:n_avail],
                        series = "Historical")
  has_actual <- "Actual" %in% names(df_oos_asset) &&
                any(!is.na(df_oos_asset$Actual))
  df_actual_oos <- if (has_actual)
    data.frame(date   = oos_dates,
               value  = as.numeric(df_oos_asset$Actual),
               series = "Actual OOS")
  else NULL
  list(df_hist = df_hist, df_actual_oos = df_actual_oos,
       oos_dates = oos_dates, first_oos = first_oos,
       last_oos = last_oos, has_actual = has_actual)
}

# ── Helper: shared ggplot base layers ────────────────────────
.oos_base_plot <- function(df_plot, first_oos, last_oos,
                           pal, lt, sh,
                           title_str, n_hist, n_oos,
                           forecast_series) {
  x_min <- min(df_plot$date)
  x_max <- last_oos + 7L

  p <- ggplot(df_plot,
              aes(x = date, y = value,
                  colour = series, linetype = series, shape = series)) +
    # geom_vline(xintercept = as.numeric(first_oos),
    #            linetype = "dashed", colour = "grey50", linewidth = 0.6) +
    # individual forecast lines + points
    geom_line(data      = subset(df_plot, series %in% forecast_series),
              linewidth = 0.8, alpha = 0.9) +
    geom_point(data     = subset(df_plot, series %in% forecast_series),
               size = 1.8, alpha = 0.9) +
    # historical — thick black solid, no points
    geom_line(data      = subset(df_plot, series == "Historical"),
              colour = "black", linetype = "solid", linewidth = 1.3) +
    # actual OOS — thick green solid + filled circles, drawn last (on top)
    geom_line(data      = subset(df_plot, series == "Actual OOS"),
              colour = "#1a7a1a", linetype = "solid", linewidth = 1.6) +
    geom_point(data     = subset(df_plot, series == "Actual OOS"),
               colour = "#1a7a1a", fill = "#1a7a1a",
               shape = 21, size = 3.0, stroke = 1.2) +
    annotate("text", x = first_oos, y = Inf,
             label = " ← Historical  |  OOS →",
             hjust = 0, vjust = 1.5, size = 3.2, colour = "grey40") +
    scale_x_date(limits      = c(x_min, x_max),
                 date_breaks  = "1 month", date_labels = "%Y-%m",
                 expand       = expansion(mult = 0.02)) +
    scale_colour_manual(  name = "Series", values = pal) +
    scale_linetype_manual(name = "Series", values = lt) +
    scale_shape_manual(   name = "Series", values = sh) +
    labs(title    = title_str,
         subtitle = paste0("Historical window: last ", n_hist,
                           " weeks  |  OOS horizon: ", n_oos, " weeks"),
         x = "Date", y = "Price (MXN)") +
    paper_theme +
    theme(axis.text.x     = element_text(angle = 45, hjust = 1, size = 9),
          legend.position = "bottom",
          legend.box      = "horizontal") +
    guides(colour   = guide_legend(nrow = 2, override.aes = list(linewidth = 1)),
           linetype = guide_legend(nrow = 2),
           shape    = guide_legend(nrow = 2))
  p
}

# ============================================================
#  create_oos_plot()  — all 11 methods + Historical + Actual OOS
# ============================================================
create_oos_plot <- function(asset_name, datos_df, df_oos_asset,
                            n_hist = 52, save_path = NULL) {

  base       <- .oos_base_data(asset_name, datos_df, df_oos_asset, n_hist)
  oos_methods <- c("ETS","ARIMA","STL","NNAR","TBATS","ARFIMA",
                   "Prophet","RF","Comb_EW","HybridModel","Comb_TA",
                   "Comb_TA_Shrunk")

  df_fct <- tidyr::pivot_longer(
    df_oos_asset[, intersect(c("Date", oos_methods), colnames(df_oos_asset))],
    cols = all_of(oos_methods), names_to = "series", values_to = "value")
  df_fct$date <- as.Date(df_fct$Date)

  df_plot <- bind_rows(base$df_hist, df_fct, base$df_actual_oos)
  df_plot$series <- factor(df_plot$series,
                            levels = c("Historical","Actual OOS", oos_methods))

  pal <- c("Historical" = "black",      "Actual OOS"     = "#1a7a1a",
           "ETS" = "#1b9e77",           "ARIMA"          = "#d95f02",
           "STL" = "#7570b3",           "NNAR"           = "#e7298a",
           "TBATS" = "#66a61e",         "ARFIMA"         = "#e6ab02",
           "Prophet" = "#17becf",       "RF"             = "#8c564b",
           "Comb_EW" = "#1f77b4",      "HybridModel"    = "#984ea3",
           "Comb_TA" = "#d62728",       "Comb_TA_Shrunk" = "#8B0000")

  lt  <- c("Historical" = "solid",      "Actual OOS"     = "solid",
           "ETS" = "dashed",            "ARIMA"          = "dotdash",
           "STL" = "longdash",          "NNAR"           = "twodash",
           "TBATS" = "dashed",          "ARFIMA"         = "dotted",
           "Prophet" = "dotdash",       "RF"             = "twodash",
           "Comb_EW" = "dashed",       "HybridModel"    = "longdash",
           "Comb_TA" = "solid",         "Comb_TA_Shrunk" = "solid")

  sh  <- c("Historical" = NA,           "Actual OOS"     = 21,
           "ETS" = 16,                  "ARIMA"          = 17,
           "STL" = 15,                  "NNAR"           = 18,
           "TBATS" = 3,                 "ARFIMA"         = 4,
           "Prophet" = 8,               "RF"             = 11,
           "Comb_EW" = 16,             "HybridModel"    = 17,
           "Comb_TA" = 15,              "Comb_TA_Shrunk" = 18)

  p <- .oos_base_plot(df_plot, base$first_oos, base$last_oos,
                      pal, lt, sh,
                      paste0("Out-of-Sample Forecast – ", asset_name),
                      n_hist, nrow(df_oos_asset), oos_methods)

  if (!is.null(save_path))
    ggsave(file.path(save_path, paste0(asset_name, "_OOS.png")),
           p, width = 14, height = 8, dpi = 400)
  p
}

# ============================================================
#  create_oos_ensemble_plot()  — Comb_TA, Comb_EW, HybridModel
#                                + Historical + Actual OOS
# ============================================================
create_oos_ensemble_plot <- function(asset_name, datos_df, df_oos_asset,
                                     n_hist = 52, save_path = NULL) {

  base        <- .oos_base_data(asset_name, datos_df, df_oos_asset, n_hist)
  ens_methods <- c("Comb_EW","HybridModel","Comb_TA")

  df_fct <- tidyr::pivot_longer(
    df_oos_asset[, c("Date", ens_methods)],
    cols = all_of(ens_methods), names_to = "series", values_to = "value")
  df_fct$date <- as.Date(df_fct$Date)

  df_plot <- bind_rows(base$df_hist, df_fct, base$df_actual_oos)
  df_plot$series <- factor(df_plot$series,
                            levels = c("Historical","Actual OOS", ens_methods))

  pal <- c("Historical"  = "black",
           "Actual OOS"  = "#1a7a1a",
           "Comb_EW"     = "#1f77b4",
           "HybridModel" = "#984ea3",
           "Comb_TA"     = "#d62728")

  lt  <- c("Historical"  = "solid",
           "Actual OOS"  = "solid",
           "Comb_EW"     = "dashed",
           "HybridModel" = "longdash",
           "Comb_TA"     = "solid")

  sh  <- c("Historical"  = NA,
           "Actual OOS"  = 21,
           "Comb_EW"     = 16,
           "HybridModel" = 17,
           "Comb_TA"     = 15)

  p <- .oos_base_plot(df_plot, base$first_oos, base$last_oos,
                      pal, lt, sh,
                      paste0("OOS Ensemble Forecast – ", asset_name),
                      n_hist, nrow(df_oos_asset), ens_methods)

  if (!is.null(save_path))
    ggsave(file.path(save_path, paste0(asset_name, "_OOS_ensemble.png")),
           p, width = 14, height = 8, dpi = 400)
  p
}

# ── Generate OOS charts for every asset ──────────────────────
cat("\nGenerating OOS charts...\n")
for (i in 2:C_loop) {
  asset <- names(datos[i])

  df_oos_ast <- forecasts_oos[forecasts_oos$Asset == asset, ]
  if (nrow(df_oos_ast) == 0) next

  # Full model chart
  p_oos <- create_oos_plot(asset, datos, df_oos_ast,
                           n_hist = 52, save_path = graf_path)
  print(p_oos)

  # Ensemble-only chart
  p_ens <- create_oos_ensemble_plot(asset, datos, df_oos_ast,
                                    n_hist = 52, save_path = graf_path)
  print(p_ens)

  cat("  \u2714 OOS charts:", asset, "\n")
}


# ============================================================
#  FINAL SUMMARY
# ============================================================
cat("\n✔ TAFE v5.1 completed.\n")
cat("  Files generated:\n")
cat("  • forecasts_complete_v5.csv    (in-sample test forecasts)\n")
cat("  • error_metrics_v5.csv         (in-sample error metrics)\n")
cat("  • series_information_v5.csv    (series summary + TA improvement)\n")
cat("  • TA_best_weights_v5.csv       (optimal TA weights per asset)\n")
cat("  • forecasts_OOS_v5.csv         (OOS forecasts with Actual column filled)\n")
cat("  • metrics_OOS_v5.1.csv         (OOS error metrics per asset & method)\n")
cat("  • DM_HLN_results_v5.1.txt      (DM & HLN tables + win ranking)\n")
cat("  • charts/*_individual.png\n")
cat("  • charts/*_ensembles.png\n")
cat("  • charts/*_TA_optimized.png\n")
cat("  • charts/*_OOS.png             (historical + OOS forecasts + Actual OOS line)\n")
cat("  • charts/boxplot_SMAPE_v5.png\n")
cat("  • heatmap_DM_pval_v5.1.png\n")
cat("  • heatmap_HLN_pval_v5.1.png\n")
cat("  • heatmap_DM_stat_v5.1.png\n")
cat("  • heatmap_DM_superiority_v5.1.png\n")
