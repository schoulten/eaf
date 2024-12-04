# Bibliotecas
from shiny import ui, App, render
import faicons as fa
from pathlib import Path
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from shinywidgets import output_widget, render_widget


# Dados
dados = pd.read_parquet("dados/dados.parquet")
cenarios = pd.read_parquet("dados/cenarios.parquet")
previsao = pd.read_parquet("dados/previsao.parquet")

# Interface do Usuário
app_ui = ui.page_navbar(
    ui.head_content(ui.include_css(Path(__file__).parent / "www" / "styles.css")),
    ui.nav_panel(
        fa.icon_svg("chart-line", fill = "#336633"),
        ui.layout_sidebar(
            ui.sidebar(
                ui.card("...")
                ),
            ui.navset_card_tab(
                ui.nav_panel("Previsão", output_widget("fanchart")),
                ui.nav_panel("Dados", output_widget("df")),
                ui.nav_panel("Cenários", ui.output_data_frame("cenario"))
                )
            )
    ),
    title = "App Emplacamentos",
    fillable = True
)

# Servidor
def server(input, output, session):
    
    @render_widget
    def fanchart():
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
                xanchor = "right",
                x = 1
            )
        )
        return fig
    
    @render_widget
    def df():
        fig = make_subplots(
            rows = 2, 
            cols = 3,
            specs = [
                [{"rowspan": 2}, {}, {}],
                [None, {}, {}]
                ],
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
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 1, 
            col = 2
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["juros"],
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 1, 
            col = 3
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["cambio"],
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 2, 
            col = 2
            )
        fig.add_trace(
            go.Scatter(
                x = dados["ano_mes"], 
                y = dados["producao_industrial"],
                mode = "lines",
                line_width = 2,
                showlegend = False
                ),
            row = 2, 
            col = 3
            )
        return fig
    
    @render.data_frame
    def cenario():
        return (
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

# Dashboard
app = App(app_ui, server, static_assets = Path(__file__).parent / "www")