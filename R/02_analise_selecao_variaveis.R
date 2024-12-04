
# Pacotes -----------------------------------------------------------------


# Carrega pacotes
library(arrow)
library(dplyr)
library(tsibble)
library(feasts)
library(fabletools)
library(tidyr)


# Dados -------------------------------------------------------------------


# Importa dados
dados <- arrow::read_parquet("dados/dados.parquet")

# Converter em tsibble
dados_tsb <- dados |> 
  dplyr::mutate(ano_mes = tsibble::yearmonth(ano_mes)) |> 
  tsibble::as_tsibble(index = "ano_mes")


# Análise Exploratória ----------------------------------------------------

# Evolução
fabletools::autoplot(dados_tsb, emplacamentos)

# Análise de correlação
cor(tidyr::drop_na(dados[2:7]))

# Autocorrelação
dados_tsb |> feasts::ACF(emplacamentos) |> fabletools::autoplot()
dados_tsb |> feasts::ACF(tsibble::difference(emplacamentos)) |> fabletools::autoplot()
# Modelo candidato: MA(12)

# Autocorrelação parcial
dados_tsb |> feasts::PACF(emplacamentos) |> fabletools::autoplot()
dados_tsb |> feasts::PACF(tsibble::difference(emplacamentos)) |> fabletools::autoplot()
# Modelo candidato: AR(1)

# Correlação cruzada
dados_tsb |> feasts::CCF(emplacamentos, pib_real) |> fabletools::autoplot()
dados_tsb |> feasts::CCF(emplacamentos, inflacao) |> fabletools::autoplot()
dados_tsb |> feasts::CCF(emplacamentos, juros) |> fabletools::autoplot()
dados_tsb |> feasts::CCF(emplacamentos, cambio) |> fabletools::autoplot()
dados_tsb |> feasts::CCF(emplacamentos, producao_industrial) |> fabletools::autoplot()

# Sazonalidade
feasts::gg_season(dados_tsb, emplacamentos)
