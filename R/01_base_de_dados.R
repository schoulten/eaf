
# Pacotes -----------------------------------------------------------------


# Carrega pacotes
library(httr2)
library(readxl)
library(rbcb)
library(sidrar)
library(dplyr)
library(lubridate)
library(tidyr)
library(arrow)
library(tzdb)


# Coleta de dados ---------------------------------------------------------


# Organização de arquivos
pasta_dados <- "dados"
if (!dir.exists(pasta_dados)) {dir.create(pasta_dados)}

# Emplacamento de caminhões
url <- "https://anfavea.com.br/docs/SeriesTemporais_Autoveiculos.xlsm"

url |> 
  httr2::request() |> 
  httr2::req_perform(path = paste0(pasta_dados, "/dados_anfavea.xlsm"))

dados_brutos_emplacamentos <- readxl::read_excel(
  path = paste0(pasta_dados, "/dados_anfavea.xlsm"),
  sheet = "Séries_Temporais_Autoveículos",
  col_names = c("ano_mes", "emplacamentos"),
  col_types = c("date", rep("skip", 15), "numeric", rep("skip", 9)),
  skip = 5
)

# PIB mensal - valores correntes
# Taxa de juros - Selic acumulada no mês
# Dólar americano (venda) - média de período
dados_brutos_bcb <- rbcb::get_series(
  code = c("pib" = 4380, "juros" = 4390, "cambio" = 3698), 
  start_date = min(dados_brutos_emplacamentos$ano_mes)
  )

# Inflação
# IPCA - Número-índice (base: dezembro de 1993 = 100) (Número-índice)
dados_brutos_inflacao <- sidrar::get_sidra(api = "/t/1737/n1/all/v/2266/p/all/d/v2266%2013")

# Produção Industrial
dados_brutos_producao_industrial <- sidrar::get_sidra(api = "/t/8888/n1/all/v/12607/p/all/c544/129314/d/v12607%205")


# Tratamento de dados -----------------------------------------------------

# Emplacamentos
dados_emplacamentos <- dados_brutos_emplacamentos |> 
  dplyr::filter(ano_mes >= max(dados_brutos_emplacamentos$ano_mes) - lubridate::years(10))

# Inflação
dados_inflacao <- dados_brutos_inflacao |> 
  dplyr::mutate(
    ano_mes = lubridate::ym(`Mês (Código)`),
    indice = Valor,
    inflacao = ((indice / dplyr::lag(indice)) - 1) * 100,
    .keep = "none"
  ) |> 
  dplyr::as_tibble() |> 
  dplyr::filter(ano_mes >= max(dados_brutos_emplacamentos$ano_mes) - lubridate::years(10))

# Deflaciona PIB
dados_pib <- dados_brutos_bcb$pib |> 
  dplyr::rename("ano_mes" = "date") |> 
  dplyr::left_join(y = dados_inflacao, by = "ano_mes") |>
  dplyr::mutate(
    pib_real = (indice[ano_mes == max(dados_inflacao$ano_mes)] / indice) * pib
    ) |> 
  dplyr::select("ano_mes", "pib_real") |> 
  dplyr::filter(ano_mes >= max(dados_brutos_emplacamentos$ano_mes) - lubridate::years(10))

# Juros e Câmbio
dados_bcb <- dplyr::full_join(
  x = dados_brutos_bcb$juros |> 
    dplyr::mutate(
      juros = dplyr::case_when( # último dado da Selic não é do mês completo
        date == max(date) & lubridate::day(Sys.Date()) < 31 ~ NA,
        .default = juros
        )
      ), 
  y = dados_brutos_bcb$cambio, 
  by = "date"
  ) |>
  dplyr::rename("ano_mes" = "date") |> 
  dplyr::arrange("ano_mes") |> 
  dplyr::filter(ano_mes >= max(dados_brutos_emplacamentos$ano_mes) - lubridate::years(10))

# Produção Industrial
dados_producao_industrial <- dados_brutos_producao_industrial |> 
  dplyr::mutate(
    ano_mes = lubridate::ym(`Mês (Código)`),
    producao_industrial = Valor,
    .keep = "none"
  ) |> 
  dplyr::as_tibble() |> 
  dplyr::filter(ano_mes >= max(dados_brutos_emplacamentos$ano_mes) - lubridate::years(10))

# Cruzamento de dados
dados <- dados_emplacamentos |> 
  dplyr::full_join(y = dados_pib, by = "ano_mes") |> 
  dplyr::full_join(y = dplyr::select(dados_inflacao, -"indice"), by = "ano_mes") |> 
  dplyr::full_join(y = dados_bcb, by = "ano_mes") |> 
  dplyr::full_join(y = dados_producao_industrial, by = "ano_mes")


# Disponibilização de dados -----------------------------------------------

# Salvar arquivo parquet
arrow::write_parquet(dados, paste0(pasta_dados, "/dados.parquet"))
