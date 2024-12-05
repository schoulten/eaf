

# Pacotes -----------------------------------------------------------------


# Carrega pacotes
library(arrow)
library(modeltime)
library(modeltime.ensemble)
library(readr)


# Dados -------------------------------------------------------------------


# Importa cenários
cenarios <- arrow::read_parquet("dados/cenarios.parquet")

# Cria dummies se inexistentes
if (!all(c(month.abb[1:11], "d2020") %in% colnames(cenarios))) {
  cenarios <- cenarios |>
  dplyr::bind_cols(
    cenarios |>
      dplyr::mutate(ano_mes = tsibble::yearmonth(ano_mes)) |>
      tsibble::as_tsibble(index = "ano_mes") |>
      dplyr::select("ano_mes", "pib_real") |>
      as.ts() |>
      forecast::seasonaldummy()
  ) |>
  dplyr::mutate(
    d2020 = dplyr::case_when(
      ano_mes >= lubridate::ymd("2020-03-01") & ano_mes <= lubridate::ymd("2020-07-01") ~ 1,
      .default = 0
      )
    )
}



# Importa dados de modelagem
modelagem <- readRDS("dados/modelagem.rds")


# Previsão ----------------------------------------------------------------


# Produz previsão
previsao <- modelagem[["modelo"]] |> 
  modeltime::modeltime_calibrate(new_data = rsample::testing(modelagem[["amostras"]])) |>
  modeltime::modeltime_refit(modelagem[["dados"]], resamples = modelagem[["plano_vc"]]) |> 
  modeltime::modeltime_forecast(
    new_data = cenarios,
    conf_interval = 0.95, 
    actual_data = modelagem[["dados"]]
  )

# Visualiza previsão
# modeltime::plot_modeltime_forecast(previsao)

# Salva previsões
arrow::write_parquet(previsao, "dados/previsao.parquet")
readr::write_csv(previsao, "dados/previsao.csv")
