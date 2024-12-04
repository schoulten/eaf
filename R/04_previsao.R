

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


# Cenários ----------------------------------------------------------------


# Função de automatização de cenários
cenario_xgboost_univariado <- function(y) {
  
  y <- dados |> dplyr::select(!!y) |> colnames()
  form = as.formula(paste0(y, " ~ ano_mes + d2020"))
  amostras <- timetk::time_series_split(dados, ano_mes, assess = 12, cumulative = TRUE)
  
  d2020 <- dados |>
    timetk::future_frame(ano_mes, 12) |> 
    dplyr::mutate(
      d2020 = dplyr::case_when(
        ano_mes >= lubridate::ymd("2020-03-01") & 
          ano_mes <= lubridate::ymd("2020-07-01") ~ 1,
        .default = 0
        )
      )
  
  cenario <- workflows::workflow() |> 
    workflows::add_recipe(
      recipes::recipe(form, data = rsample::training(amostras)) |> 
        timetk::step_timeseries_signature(ano_mes) |>
        recipes::step_rm(ano_mes) |>
        recipes::step_zv(recipes::all_predictors()) |>
        recipes::step_dummy(recipes::all_nominal_predictors(), one_hot = TRUE)
    ) |> 
    workflows::add_model(
      parsnip::boost_tree(mode = "regression", min_n = 2) |> 
        parsnip::set_engine("xgboost")
    ) |> 
    fit(data = rsample::training(amostras)) |> 
    modeltime::modeltime_table() |>
    modeltime::modeltime_calibrate(new_data = rsample::testing(amostras)) |>
    modeltime::modeltime_refit(dados) |> 
    modeltime::modeltime_forecast(new_data = d2020) |>
    dplyr::select("ano_mes" = ".index", !!y := ".value")
  return(cenario)
}


# Gera cenários para exógenas
cenarios_exog <- purrr::map(
  .x = c("pib_real", "inflacao", "juros", "cambio", "producao_industrial"),
  .f = cenario_xgboost_univariado
  ) |> 
  purrr::reduce(dplyr::full_join, by = "ano_mes")

cenarios_exog_obs <- dados_brutos |> # Algumas variáveis podem ter dados já divulgados
  dplyr::filter(                     # para o período da previsão, mas que não foram 
    ano_mes > dados_brutos |>        # usados nos modelos. Aqui usamos estes dados 
      dplyr::select("ano_mes", "emplacamentos") |> # observados, se existirem, como cenário
      tidyr::drop_na() |> 
      dplyr::pull(ano_mes) |>
      max()
  ) |> 
  dplyr::select(-"emplacamentos")

# Junta cenários e dummies
cenarios <- cenarios_exog |> 
  dplyr::left_join(cenarios_exog_obs, by = "ano_mes", suffix = c("", "_obs")) |> 
  dplyr::mutate(
    pib_real = dplyr::coalesce(pib_real_obs, pib_real),
    inflacao = dplyr::coalesce(inflacao_obs, inflacao),
    juros = dplyr::coalesce(juros_obs, juros),
    cambio = dplyr::coalesce(cambio_obs, cambio),
    producao_industrial = dplyr::coalesce(producao_industrial_obs, producao_industrial),
    d2020 = dplyr::case_when(
      ano_mes >= lubridate::ymd("2020-03-01") & 
        ano_mes <= lubridate::ymd("2020-07-01") ~ 1,
      .default = 0
    )
  ) |> 
  dplyr::select(!dplyr::contains("_obs")) |> 
  dplyr::bind_cols(
    cenarios_exog |>
      dplyr::mutate(ano_mes = tsibble::yearmonth(ano_mes)) |>
      tsibble::as_tsibble(index = "ano_mes") |>
      dplyr::select("ano_mes", "inflacao") |>
      as.ts() |>
      forecast::seasonaldummy()
  )

# Visualiza cenários
dados |>
  dplyr::bind_rows(cenarios) |>
  dplyr::select(1:7) |>
  tidyr::pivot_longer(cols = -"ano_mes") |> 
  ggplot2::ggplot() + 
    ggplot2::aes(x = ano_mes, y = value) + 
    ggplot2::geom_vline(xintercept = min(cenarios$ano_mes), linetype = "dashed", color = "blue") + 
    ggplot2::geom_line() + 
    ggplot2::facet_wrap(~name, scales = "free")

# Salva cenários
arrow::write_parquet(cenarios, "dados/cenarios.parquet")



# Previsão ----------------------------------------------------------------


# Produz previsão
previsao <- modelo_ensemble |> 
  modeltime::modeltime_calibrate(new_data = rsample::testing(amostras)) |>
  modeltime::modeltime_refit(dados, resamples = plano_vc) |> 
  modeltime::modeltime_forecast(new_data = cenarios, conf_interval = 0.95, actual_data=dados)

# Visualiza previsão
plot_modeltime_forecast(previsao)

# Salva previsões
arrow::write_parquet(previsao, "dados/previsao.parquet")
