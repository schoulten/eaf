# Bibliotecas
from shiny import ui, App, render, Inputs, Outputs, Session
import faicons as fa
from pathlib import Path
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from shinywidgets import output_widget, render_widget
import subprocess
import os

# Dados
dados = pd.read_parquet("dados/dados.parquet")
cenarios = pd.read_parquet("dados/cenarios.parquet")

# Interface do Usuário
app_ui = ui.page_navbar(
    ui.head_content(ui.include_css(Path(__file__).parent / "www" / "styles.css")),
    ui.nav_panel(
        fa.icon_svg("chart-line"),
        ui.navset_pill_list(
            ui.nav_panel(
                "1. Analisar dados", 
                ui.card(
                    output_widget("df"), 
                    height = "100%", 
                    min_height = "600px", 
                    full_screen = True, 
                    fill = True
                    )
                ),
            ui.nav_panel(
                "2. Definir cenário", 
                ui.card(
                    ui.output_data_frame("cenario"), 
                    height = "100%", 
                    min_height = "600px", 
                    full_screen = True, 
                    fill = True
                    )
                ),
            ui.nav_panel(
                "3. Gerar previsão", 
                ui.card(
                    output_widget("fanchart"),
                    ui.card_footer(
                        ui.download_link("download", "", icon = fa.icon_svg("download"))
                        ),
                    height = "100%", 
                    min_height = "600px", 
                    full_screen = True, 
                    fill = True
                    )
                ),
            widths = [2, 10]
        ),
        
    ),
    title = ui.div(
        "App Emplacamentos ",
        ui.popover(
            fa.icon_svg("circle-info"),
            ui.markdown("App de análise e simulação preditiva em 3 etapas para o **Nº de Empalacamentos de Caminhões** (ANFAVEA).")
        )
    ),
    window_title = "App Emplacamentos",
    fillable = True
)

# Servidor
def server(input: Inputs, output: Outputs, session: Session):
    
    @render_widget
    def fanchart():
        ui.notification_show("Salvando cenários...", duration = 5)
        (
            cenario
            .data_view()
            .rename(
                columns = {
                    "Período": "ano_mes",
                    "Produto Interno Bruto (R$, deflacionado)": "pib_real",
                    "Taxa de Inflação (IPCA, var. %)": "inflacao",
                    "Taxa de Juros (Selic, % a.m.)": "juros",
                    "Taxa de Câmbio (dólar, média)": "cambio",
                    "Produção Industrial (índice, s.a.)": "producao_industrial"
                }
            )
            .assign(
                ano_mes = lambda x: pd.to_datetime(x.ano_mes, format = "%m/%Y"),
                pib_real = lambda x: x.pib_real.astype(float),
                inflacao = lambda x: x.inflacao.astype(float),
                juros = lambda x: x.juros.astype(float),
                cambio = lambda x: x.cambio.astype(float),
                producao_industrial = lambda x: x.producao_industrial.astype(float),
                )
            .to_parquet("dados/cenarios.parquet")
        )
        
        ui.notification_show("Produzindo previsões...", duration = 10)
        subprocess.call(["Rscript", "--vanilla", "R/06_previsao.R"])
        ui.notification_show("Simulação concluída!", duration = 5)

        previsao = pd.read_parquet("dados/previsao.parquet")

        obsvd = previsao.query("`.key` == 'actual'")
        frcst = previsao.query("`.key` == 'prediction'")
        fig = go.Figure()
        fig.add_trace(
            go.Scatter(
                x = frcst[".index"], 
                y = frcst[".value"].astype(int),
                name = "Previsão",
                mode = "lines",
                line_color = "blue",
                line_width = 2
                )
            )
        fig.add_trace(
            go.Scatter(
                x = frcst[".index"], 
                y = frcst[".conf_lo"].astype(int), 
                name = "Intervalo inferior",
                mode = "lines",
                fill = None,
                line_color = "blue",
                showlegend = False
                )
            )
        fig.add_trace(
            go.Scatter(
                x = frcst[".index"], 
                y = frcst[".conf_hi"].astype(int), 
                name = "Intervalo superior",
                mode = "lines",
                fill = "tonexty",
                line_color = "blue",
                showlegend = False
                )
            )
        fig.add_trace(
            go.Scatter(
                x = obsvd[".index"], 
                y = obsvd[".value"], 
                name = "Emplacamentos",
                mode = "lines",
                line_color = "black",
                line_width = 2
                )
            )
        fig.update_layout(
            title = None,
            xaxis_title = None,
            yaxis_title = "Nº de Emplacamentos",
            hovermode = "x",
            legend = dict(
                orientation = "h",
                yanchor = "bottom",
                y = 1,
                xanchor = "left",
                x = 0
            )
        )
        return fig
    
    @render_widget
    def df():
        fig = make_subplots(
            rows = 5, 
            cols = 1,
            subplot_titles =(
                "Produto Interno Bruto (R$, deflacionado)",
                "Taxa de Inflação (IPCA, var. %)",
                "Taxa de Juros (Selic, % a.m.)",
                "Taxa de Câmbio (dólar, média)",
                "Produção Industrial (índice, s.a.)"
                )
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["pib_real"],
                name = "Produto Interno Bruto (R$, deflacionado)",
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 1, 
            col = 1
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["inflacao"],
                name = "Taxa de Inflação (IPCA, var. %)",
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 2, 
            col = 1
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["juros"],
                name = "Taxa de Juros (Selic, % a.m.)",
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 3, 
            col = 1
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["cambio"],
                name = "Taxa de Câmbio (dólar, média)",
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 4, 
            col = 1
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["producao_industrial"],
                name = "Produção Industrial (índice, s.a.)",
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 5, 
            col = 1
            )
        return fig
    
    @render.data_frame
    def cenario():
        df_cenarios = (
            cenarios
            .assign(ano_mes = lambda x: pd.to_datetime(x.ano_mes).dt.strftime("%m/%Y"))
            .filter(["ano_mes", "pib_real", "inflacao", "juros", "cambio", "producao_industrial"])
            .rename(
                columns = {
                    "ano_mes": "Período",
                    "pib_real": "Produto Interno Bruto (R$, deflacionado)",
                    "inflacao": "Taxa de Inflação (IPCA, var. %)",
                    "juros": "Taxa de Juros (Selic, % a.m.)",
                    "cambio": "Taxa de Câmbio (dólar, média)",
                    "producao_industrial": "Produção Industrial (índice, s.a.)"
                }
            )
            .round(2)
        )
        return render.DataGrid(df_cenarios, editable = True)
    
    @cenario.set_patch_fn
    def _(*, patch: render.CellPatch) -> render.CellValue:
        if patch["column_index"] in [1, 6]:
            return float(patch["value"])
        return str(patch["value"])
    
    @render.download(filename = "emplacamentos.csv")
    def download():
        arquivo = os.path.join(os.path.dirname(__file__), "../dados/previsao.csv")
        return arquivo

# Dashboard
app = App(app_ui, server, static_assets = Path(__file__).parent / "www")
