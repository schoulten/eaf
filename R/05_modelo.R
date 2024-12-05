

# Pacotes -----------------------------------------------------------------


# Carrega pacotes
library(arrow)
library(tidyr)
library(dplyr)
library(tsibble)
library(forecast)
library(workflows)
library(recipes)
library(modeltime)
library(parsnip)
library(modeltime.ensemble)
library(tune)
library(modeltime.resample)
library(timetk)
library(rsample)


# Dados -------------------------------------------------------------------


# Importa dados
dados_brutos <- arrow::read_parquet("dados/dados.parquet")

# Trata NAs e adiciona dummies
dados <- dados_brutos |> 
  dplyr::filter(
    ano_mes <= dados_brutos |>
      dplyr::select("ano_mes", "emplacamentos") |> 
      tidyr::drop_na() |> 
      dplyr::pull(ano_mes) |>
      max(),
    ano_mes >= lubridate::ymd("2015-01-01")
  ) |> 
  tidyr::fill(-emplacamentos, .direction = "downup") |> 
  dplyr::bind_cols(
    dados_brutos |>
      dplyr::filter(
        ano_mes <= dados_brutos |>
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


# Modelos -----------------------------------------------------------------


# Modelo 1: Random Forest
modelo_rf <- workflows::workflow() |> 
  workflows::add_recipe(
    recipes::recipe(emplacamentos ~ ., data = dados)
  ) |> 
  workflows::add_model(
    parsnip::rand_forest(mode = "regression", min_n = 2) |> 
      parsnip::set_engine("ranger")
  ) |> 
  fit(data = dados)

# Modelo 2: XGBoost
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
modelos_tbl <- modeltime::modeltime_table(modelo_rf, modelo_xgb)

# Validação cruzada
plano_vc <- modeltime.resample::time_series_cv(
  data = dados,
  date_var = ano_mes,
  initial = 80,
  assess = 12,
  cumulative = TRUE
)
validacao_cruzada <- modeltime.resample::modeltime_fit_resamples(
  modelos_tbl,
  resamples = plano_vc,
  control = tune::control_resamples(verbose = TRUE)
)

# Modelo 3: Ensemble
amostras <- timetk::time_series_split(dados, ano_mes, assess = 12, cumulative = TRUE)
modelo_ensemble <- validacao_cruzada |> 
  modeltime.ensemble::ensemble_model_spec(
    model_spec = parsnip::linear_reg() |> parsnip::set_engine("lm"),
    control = tune::control_grid(verbose = TRUE)
  ) |> 
  modeltime::modeltime_table()

# Salva dados de modelo
saveRDS(
  list(
    "dados" = dados, 
    "amostras" = amostras,
    "plano_vc" = plano_vc,
    "modelo" = modelo_ensemble
    ), 
    "dados/modelagem.rds",
    compress = FALSE
    )
