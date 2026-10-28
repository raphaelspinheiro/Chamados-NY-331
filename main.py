import argparse
import csv
import logging
import os
import time
import pandas as pd
import requests
from datetime import date
from pathlib import Path
from dotenv import load_dotenv

URL = "https://data.cityofnewyork.us/resource/erm2-nwe9.json"
TAMANHO_PAGINA = 50_000
TENTATIVAS = 3

PASTA_PROJETO = Path(__file__).resolve().parent
PASTA_DADOS = PASTA_PROJETO / "dados"
PASTA_LOGS = PASTA_PROJETO / "logs"

COLUNAS = [
    "unique_key",
    "created_date",
    "closed_date",
    "due_date",
    "resolution_action_updated_date",
    "status",
    "agency",
    "agency_name",
    "complaint_type",
    "descriptor",
    "location_type",
    "open_data_channel_type",
    "borough",
    "city",
    "incident_zip",
    "community_board",
    "resolution_description",
    "latitude",
    "longitude",
]


def configurar_log() -> None:
    PASTA_LOGS.mkdir(exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
        handlers=[
            logging.FileHandler(PASTA_LOGS / "extracao_311.log", encoding="utf-8"),
            logging.StreamHandler(),
        ],
    )


def proximo_mes(ano: int, mes: int) -> tuple[int, int]:
    return (ano + 1, 1) if mes == 12 else (ano, mes + 1)


def mes_anterior(ano: int, mes: int) -> tuple[int, int]:
    return (ano - 1, 12) if mes == 1 else (ano, mes - 1)


def texto_para_mes(texto: str) -> tuple[int, int]:
    ano, mes = texto.split("-")
    return int(ano), int(mes)


def periodo_padrao() -> tuple[tuple[int, int], tuple[int, int]]:
    """Últimos 3 meses fechados."""
    hoje = date.today()
    fim = mes_anterior(hoje.year, hoje.month)
    inicio = mes_anterior(*mes_anterior(*fim))
    return inicio, fim


def listar_meses(inicio: tuple[int, int], fim: tuple[int, int]) -> list[tuple[int, int]]:
    meses = []
    atual = inicio
    while atual <= fim:
        meses.append(atual)
        atual = proximo_mes(*atual)
    return meses


def criar_sessao() -> requests.Session:
    sessao = requests.Session()
    token = os.getenv("NYC_APP_TOKEN")
    if token:
        sessao.headers["X-App-Token"] = token
    return sessao


def baixar_pagina(sessao: requests.Session, filtro: str, offset: int) -> list[dict]:
    params = {
        "$where": filtro,
        "$order": "unique_key",
        "$limit": TAMANHO_PAGINA,
        "$offset": offset,
    }
    for tentativa in range(1, TENTATIVAS + 1):
        try:
            resposta = sessao.get(URL, params=params, timeout=120)
            resposta.raise_for_status()
            return resposta.json()
        except requests.RequestException as erro:
            if tentativa == TENTATIVAS:
                raise
            espera = 10 * tentativa
            logging.warning("Falha na página %s (tentativa %s): %s. Nova tentativa em %ss",
                            offset, tentativa, erro, espera)
            time.sleep(espera)
    return []


def baixar_mes(sessao: requests.Session, ano: int, mes: int) -> pd.DataFrame:
    ano_seg, mes_seg = proximo_mes(ano, mes)
    filtro = (
        f"created_date >= '{ano}-{mes:02d}-01T00:00:00' "
        f"AND created_date < '{ano_seg}-{mes_seg:02d}-01T00:00:00'"
    )

    registros = []
    offset = 0
    while True:
        pagina = baixar_pagina(sessao, filtro, offset)
        registros.extend(pagina)
        logging.info("%s-%02d: %s linhas baixadas", ano, mes, len(registros))
        if len(pagina) < TAMANHO_PAGINA:
            break
        offset += TAMANHO_PAGINA

    return pd.DataFrame(registros)


def preparar(df: pd.DataFrame) -> pd.DataFrame:
    df = df.reindex(columns=COLUNAS)
    texto = df.select_dtypes(include="object").columns
    df[texto] = df[texto].apply(
        lambda col: col.str.replace(r"[\r\n]+", " ", regex=True).str.strip()
    )
    return df


def salvar(df: pd.DataFrame, arquivo: Path) -> None:
    temporario = arquivo.with_suffix(".tmp")
    df.to_csv(temporario, index=False, encoding="utf-8",
              quoting=csv.QUOTE_ALL, lineterminator="\n")
    temporario.replace(arquivo)  # só substitui o arquivo final se a gravação terminou


def main() -> None:
    parser = argparse.ArgumentParser(description="Extração dos chamados 311 de NY")
    parser.add_argument("--inicio", help="Mês inicial no formato AAAA-MM")
    parser.add_argument("--fim", help="Mês final no formato AAAA-MM")
    parser.add_argument("--forcar", action="store_true", help="Baixa de novo meses já baixados")
    args = parser.parse_args()

    load_dotenv(PASTA_PROJETO / ".env")
    configurar_log()
    PASTA_DADOS.mkdir(exist_ok=True)

    inicio_padrao, fim_padrao = periodo_padrao()
    inicio = texto_para_mes(args.inicio) if args.inicio else inicio_padrao
    fim = texto_para_mes(args.fim) if args.fim else fim_padrao
    hoje = date.today()
    mes_atual = (hoje.year, hoje.month)

    sessao = criar_sessao()
    resumo = {"baixados": 0, "ignorados": 0, "erros": 0}

    for ano, mes in listar_meses(inicio, fim):
        arquivo = PASTA_DADOS / f"chamados_311_{ano}-{mes:02d}.csv"

        if arquivo.exists() and (ano, mes) < mes_atual and not args.forcar:
            logging.info("%s já existe, ignorado", arquivo.name)
            resumo["ignorados"] += 1
            continue

        try:
            inicio_tempo = time.time()
            df = preparar(baixar_mes(sessao, ano, mes))
            salvar(df, arquivo)
            logging.info("%s salvo: %s linhas em %.0fs",
                         arquivo.name, len(df), time.time() - inicio_tempo)
            resumo["baixados"] += 1
        except Exception as erro: 
            logging.error("Erro em %s-%02d: %s", ano, mes, erro)
            resumo["erros"] += 1

    logging.info("Fim. Baixados: %(baixados)s | Ignorados: %(ignorados)s | Erros: %(erros)s",
                 resumo)


if __name__ == "__main__":
    main()