# Chamados 311 de Nova York – Python, SQL Server e Power BI

Projeto de dados de ponta a ponta com uma base pública e real: os chamados do **311**, a central onde os moradores de Nova York pedem serviços e registram reclamações para a prefeitura.

São **995.685 chamados** abertos entre julho e setembro de 2026, extraídos da API oficial do NYC Open Data, tratados no SQL Server e analisados no Power BI.

**Pergunta principal:** quais problemas a cidade resolve rápido, quais ficam parados e quando a demanda chega?

---

## Fluxo

```mermaid
flowchart LR
    A[API NYC Open Data] -->|Python| B[CSV por mês]
    B -->|BULK INSERT| C[(Staging)]
    C -->|Procedures de tratamento| D[(Dimensões e fato)]
    D -->|Views| E[Power BI]
```

| Etapa | Ferramenta | O que faz |
|---|---|---|
| Extração | Python (requests, pandas) | Baixa um CSV por mês pela API, com paginação, nova tentativa em caso de falha e log |
| Carga | SQL Server (BULK INSERT) | Lê os CSVs da pasta e grava na staging, tudo como texto |
| Tratamento | SQL Server (procedures) | Converte tipos, remove duplicatas, padroniza categorias e calcula o tempo de resolução |
| Visualização | Power BI (DAX) | 3 páginas com filtros sincronizados e navegação personalizada |

---

## Estrutura do repositório

```
├── Python/
│   ├── extracao_311.py
│   └── requirements.txt
├── SQL/
│   ├── 01_criacao_banco_controle.sql
│   ├── 02_criacao_staging.sql
│   ├── 03_criacao_tabelas_finais.sql
│   ├── 04_procedures_carga_tratamento.sql
│   └── 05_views_power_bi.sql
└── Power BI/
    ├── Chamados311.pbix
    └── prints/
```

Os CSVs não estão no repositório (cerca de 650 MB). O script de extração gera todos eles.

---

## Como executar

### 1. Extração

```bash
pip install -r Python/requirements.txt
python Python/extracao_311.py                              # últimos 3 meses fechados
python Python/extracao_311.py --inicio 2026-07 --fim 2026-09
python Python/extracao_311.py --forcar                     # baixa tudo de novo
```

- Gera `dados/chamados_311_AAAA-MM.csv`, um arquivo por mês de abertura do chamado.
- Mês fechado que já foi baixado é ignorado. O mês atual é sempre baixado de novo, porque o status dos chamados ainda muda.
- Busca de 50 mil em 50 mil linhas e tenta de novo até 3 vezes se uma página falhar.
- Um token de aplicativo do NYC Open Data é opcional (variável `NYC_APP_TOKEN` no `.env`) e reduz o risco de limite de requisições.

### 2. Banco de dados

Rodar os scripts da pasta `SQL` em ordem (01 a 05). O caminho da pasta dos CSVs fica em `ctl.parametros`:

```sql
UPDATE ctl.parametros SET valor = N'C:\caminho\dados' WHERE chave = 'PASTA_DADOS';
```

O serviço do SQL Server precisa de leitura na pasta:

```
icacls "C:\caminho\dados" /grant "NT Service\MSSQLSERVER:(OI)(CI)RX" /T
```

Carga:

```sql
EXEC dw.sp_carga_completa;              -- carrega o que ainda não foi carregado
EXEC dw.sp_carga_completa @forcar = 1;  -- recarrega tudo
```

### 3. Power BI

Abrir o `.pbix`, apontar para `localhost`, banco `CHAMADOS311`, e atualizar.

---

## Banco de dados

Três schemas:

- `stg`: cópia dos CSVs, tudo como texto
- `dw`: dados tratados, em modelo estrela
- `ctl`: parâmetros, controle de carga e log de erros

| Tabela | Conteúdo |
|---|---|
| `dw.fato_chamado` | 1 linha por chamado: datas, status, tempo de resolução, faixa, órgão, tipo, canal e bairro |
| `dw.dim_calendario` | Datas de 2024 a 2027, com nomes em português |
| `dw.dim_hora` | 24 horas e período do dia (madrugada, manhã, tarde, noite) |
| `dw.dim_agencia` | Órgão responsável (NYPD, HPD, DOT…) |
| `dw.dim_tipo` | Tipo de problema, detalhe e grupo |
| `dw.dim_faixa_resolucao` | Até 1h, 1h a 24h, 1 a 7 dias, 7 a 30 dias, mais de 30 dias, em aberto |

**Carga incremental:** cada arquivo é registrado em `ctl.arquivos_carga`. Mês fechado já carregado não é processado de novo. Ao carregar, o mês é apagado e gravado de novo dentro de uma transação, então rodar duas vezes não duplica dados. Se um arquivo falhar, o erro vai para `ctl.log_erros` e os outros continuam.

---

## Regras de tratamento

Definidas a partir da análise dos dados de origem:

- **Fechado** = status `Closed` com data de fechamento preenchida.
- **Tempo de resolução** = fechamento − abertura, calculado só quando o fechamento é depois da abertura.
- **Sem prazo oficial:** a coluna `due_date` está vazia em 99,7% dos chamados. Por isso o painel usa faixas de tempo e a mediana, em vez de "% dentro do prazo".
- **Inconsistências da origem:** 595 chamados constam como fechados antes de serem abertos. Eles ficam na faixa "Data inconsistente" e fora do cálculo de tempo. Chamados com data de fechamento mas status diferente de `Closed` (provavelmente reabertos) contam como em aberto.
- **Categorias padronizadas:** tipos que diferem só por maiúscula ("PLUMBING" e "Plumbing") viram um só. Cada tipo ganha um **grupo** ("Noise - Residential" → NOISE).
- Duplicatas removidas por `unique_key`, mantendo a versão com a ação mais recente.

---

## Validação

Os totais do SQL foram conferidos direto no CSV de setembro:

| Indicador | CSV | SQL |
|---|---|---|
| Chamados | 323.630 | 323.630 |
| Fechados | 295.426 (91,29%) | 295.426 (91,29%) |
| Média de resolução | 80,93 h | 80,93 h |
| Mediana de resolução | 5,77 h | 5,77 h |
| Faixas de resolução | 68.501 / 117.522 / 62.696 / 42.346 / 4.158 | iguais |

Os três meses foram carregados sem linhas rejeitadas:

| Mês | Linhas | Extração (API) | Carga no SQL |
|---|---|---|---|
| Julho | 343.133 | 8 min 16 s | 15 s |
| Agosto | 328.922 | 2 min 45 s | 16 s |
| Setembro | 323.630 | 5 min 19 s | 23 s |

---

## Dashboard

### 1. Visão Geral
Volume, % fechados, mediana, % resolvidos em 24h e chamados em aberto. Evolução diária, faixas de resolução, canais e bairros.

![Visão Geral](Power%20BI/prints/pagina_1_visao_geral.png)

### 2. Órgãos e Problemas
Desempenho de cada órgão e dispersão volume × mediana por grupo de problema, com linhas de média que separam as prioridades.

![Órgãos e Problemas](Power%20BI/prints/pagina_2_orgaos_problemas.png)

### 3. Quando os chamados chegam
Mapa de calor por dia da semana e hora, volume e agilidade ao longo do dia e canal de abertura por período.

![Quando os chamados chegam](Power%20BI/prints/pagina_3_quando_chegam.png)

---

## Principais achados

- **93% dos chamados foram fechados e 58% resolvidos em até 24 horas.**
- **A média engana.** Em setembro, a média de resolução foi de 81 horas e a mediana, de 5,8. Poucos casos muito demorados puxam a média para cima. Por isso o painel usa a mediana como indicador principal.
- **Volume alto não é sinônimo de problema.** Barulho (210 mil chamados) e estacionamento irregular (154 mil) lideram em volume, mas são resolvidos em poucas horas.
- **O gargalo está em árvores e moradia.** Galhos e árvores, além de problemas como vazamentos, portas e janelas e condições insalubres, ficam entre 8 e 13 dias de mediana.
- **Diferença grande entre órgãos.** O Departamento de Serviços aos Desabrigados (DHS) tem mediana de 5,6 horas. O Departamento de Proteção ao Consumidor e ao Trabalhador (DCWP), de 672 horas. O Departamento de Parques (DPR) concentra 23 mil chamados em aberto.
- **A demanda não para à noite.** O pico é às segundas, por volta das 11h, mas 40% dos chamados chegam à noite ou de madrugada, e 27% no fim de semana.

---

## Limitações

- **Status é uma foto do dia da extração** (27/10/2026). Chamados em aberto podem ter sido fechados depois.
- **Efeito de maturação:** meses mais antigos tiveram mais tempo para fechar chamados demorados. Julho mostra 94,7% de fechados e média de 151 horas, contra 91,3% e 81 horas em setembro. Isso não quer dizer que setembro foi melhor. A mediana (entre 5,7 e 6,6 horas nos três meses) é o indicador mais justo para comparar períodos.
- O período cobre 3 meses. A carga incremental permite ampliar sem reprocessar o que já foi carregado.

---

## Fonte

[NYC Open Data – 311 Service Requests from 2010 to Present](https://data.cityofnewyork.us/Social-Services/311-Service-Requests-from-2010-to-Present/erm2-nwe9), da prefeitura de Nova York.

## Tecnologias

Python 3.13 (requests, pandas) · SQL Server 2025 · Power BI Desktop

---

**Raphael Pinheiro**
