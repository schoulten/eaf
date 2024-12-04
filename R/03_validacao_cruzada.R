
# Pacotes -----------------------------------------------------------------


# Carrega pacotes
library(arrow)
library(tidyr)
library(dplyr)
library(tsibble)
library(forecast)
library(modeltime.resample)
library(modeltime)
library(parsnip)
library(ranger)
library(tune)
library(modeltime.ensemble)
library(workflows)


# Dados -------------------------------------------------------------------

# Importa dados
dados <- arrow::read_parquet("dados/dados.parquet")

# Trata NAs e adiciona dummies
dados <- dados |> 
  dplyr::filter(
    ano_mes <= dados |>
      dplyr::select("ano_mes", "emplacamentos") |> 
      tidyr::drop_na() |> 
      dplyr::pull(ano_mes) |>
      max(),
    ano_mes >= lubridate::ymd("2015-01-01")
  ) |> 
  tidyr::fill(-emplacamentos, .direction = "downup") |> 
  dplyr::bind_cols(
    dados |>
      dplyr::filter(
        ano_mes <= dados |>
          dplyr::select("ano_mes", "emplacamentos") |> 
          tidyr::drop_na() |> 
          dplyr::pull(ano_mes) |>
          max(),
        ano_mes >= lubridate::ymd("2015-01-01")
      ) |> 
      dplyr::mutate(ano_mes = tsibble::yearmonth(ano_mes)) |>
      tsibble::as_tsibble(index = "ano_mes") |>
      dplyr::select("ano_mes", "emplacamentos") |>
      as.ts() |>
      forecast::seasonaldummy()
  ) |> 
  dplyr::mutate(
    d2020 = dplyr::case_when(
      ano_mes >= lubridate::ymd("2020-03-01") & ano_mes <= lubridate::ymd("2020-07-01") ~ 1,
      .default = 0
      )
    )


# Validação cruzada -------------------------------------------------------


# Plano de validação cruzada
plano_vc <- modeltime.resample::time_series_cv(
  data = dados,
  date_var = ano_mes,
  initial = 80,
  assess = 12,
  cumulative = TRUE
)

# Modelo 1: Passeio aleatório
modelo_rw <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ano_mes, data = dados)
  ) |> 
  workflows::add_model(
    modeltime::naive_reg(seasonal_period = 12) |> 
      parsnip::set_engine("snaive")
  ) |> 
  fit(data = dados)

# Modelo 2: ETS
modelo_ets <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ., data = dados)
  ) |> 
  workflows::add_model(
    modeltime::exp_smoothing(seasonal_period = 12) |> 
      parsnip::set_engine("ets")
  ) |> 
  fit(data = dados)

# Modelo 3: ARIMA
modelo_arima <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ., data = dados)
  ) |> 
  workflows::add_model(
    modeltime::arima_boost(
      min_n = 2,
      learn_rate = 0.015
    ) |> 
      parsnip::set_engine(engine = "auto_arima_xgboost")
  ) |> 
  fit(data = dados)

# Modelo 4: Random Forest
modelo_rf <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ., data = dados)
  ) |> 
  workflows::add_model(
    parsnip::rand_forest(mode = "regression", min_n = 2) |> 
      parsnip::set_engine("ranger")
  ) |> 
  fit(data = dados)

# Modelo 5: XGBoost
modelo_xgb <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ., data = dados) |> 
      recipes::step_mutate(ano_mes = as.numeric(ano_mes))
  ) |> 
  workflows::add_model(
    parsnip::boost_tree(mode = "regression", min_n = 2) |> 
      parsnip::set_engine("xgboost")
  ) |> 
  fit(data = dados)

# Tabela de modelos
modelos_tbl <- modeltime::modeltime_table(
  modelo_rw,
  modelo_ets,
  modelo_arima,
  modelo_rf,
  modelo_xgb
)

# Validação cruzada
validacao_cruzada <- modeltime.resample::modeltime_fit_resamples(
  modelos_tbl,
  resamples = plano_vc,
  control = tune::control_resamples(verbose = TRUE)
  )

# Modelo 6: Ensemble
modelo_ensemble <- validacao_cruzada |> 
  dplyr::filter(.model_desc %in% c("RANGER", "XGBOOST")) |> 
  modeltime.ensemble::ensemble_model_spec(
    model_spec = parsnip::linear_reg() |> parsnip::set_engine("lm"),
    control = tune::control_grid(verbose = TRUE)
  )


# Avaliação de performance ------------------------------------------------


# Erro médio e RMSE
validacao_cruzada |> 
  modeltime.resample::unnest_modeltime_resamples() |>
  dplyr::group_by(.model_desc) |> 
  dplyr::summarise(
    me = mean(emplacamentos - .pred),
    rmse = sqrt(mean((emplacamentos - .pred)^2))
  ) |> 
  dplyr::bind_rows(
    validacao_cruzada |> # Modelo ensemble
      dplyr::filter(.model_desc %in% c("RANGER", "XGBOOST")) |> 
      modeltime.resample::unnest_modeltime_resamples() |>
      dplyr::group_by(.resample_id, .row_id) |>
      dplyr::summarise(
        .pred = mean(.pred), 
        emplacamentos = dplyr::first(emplacamentos), 
        .groups = "drop"
      ) |> 
      dplyr::summarise(
        me = mean(emplacamentos - .pred),
        rmse = sqrt(mean((emplacamentos - .pred)^2)),
        .model_desc = "Ensemble"
      )
  ) |> 
  dplyr::arrange(rmse)

# Erros por horizonte de previsão (1, 2, 3, ...)
validacao_cruzada |> 
  modeltime.resample::unnest_modeltime_resamples() |>
  dplyr::group_by(.resample_id, .model_desc) |> 
  dplyr::mutate(h = 1:dplyr::n()) |>
  dplyr::group_by(.model_desc, h) |> 
  dplyr::summarise(
    me = mean(emplacamentos - .pred),
    rmse = sqrt(mean((emplacamentos - .pred)^2))
  ) |> 
  dplyr::bind_rows(
    validacao_cruzada |> 
      dplyr::filter(.model_desc %in% c("RANGER", "XGBOOST")) |> 
      modeltime.resample::unnest_modeltime_resamples() |>
      dplyr::group_by(.resample_id, .row_id) |>
      dplyr::summarise(
        .pred = mean(.pred), 
        emplacamentos = dplyr::first(emplacamentos), 
        .groups = "drop"
      ) |> 
      dplyr::group_by(.model_desc = "Ensemble", .resample_id) |> 
      dplyr::mutate(h = 1:dplyr::n()) |>
      dplyr::group_by(.model_desc, h) |> 
      dplyr::summarise(
        me = mean(emplacamentos - .pred),
        rmse = sqrt(mean((emplacamentos - .pred)^2))
      )
  ) |> 
  ggplot2::ggplot() +
  ggplot2::aes(x = h, y = rmse, color = .model_desc) +
  ggplot2::geom_point()
# Modelo final: ensemble
