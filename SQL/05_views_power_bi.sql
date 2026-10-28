-- 05 - Views para o Power BI e consultas de conferência

USE CHAMADOS311;
GO

-- Fato sem os textos longos, que não são usados nos visuais
CREATE OR ALTER VIEW dw.vw_fato_chamado
AS
SELECT
    unique_key,
    data_abertura,
    hora_abertura,
    data_fechamento,
    status,
    fl_fechado,
    horas_resolucao,
    id_faixa,
    sk_agencia,
    sk_tipo,
    canal,
    borough
FROM dw.fato_chamado;
GO

CREATE OR ALTER VIEW dw.vw_dim_agencia
AS
SELECT sk_agencia, agency AS sigla, agency_name AS orgao
FROM dw.dim_agencia;
GO

CREATE OR ALTER VIEW dw.vw_dim_tipo
AS
SELECT sk_tipo, grupo, complaint_type AS tipo, descriptor AS detalhe
FROM dw.dim_tipo;
GO

/* =========================== Conferência =========================== */

-- Controle das cargas
SELECT * FROM ctl.arquivos_carga ORDER BY id_carga;
SELECT * FROM ctl.log_erros ORDER BY id_erro DESC;

-- Totais por mês
SELECT
    c.ano_mes,
    COUNT(*)                                                       AS chamados,
    SUM(CAST(f.fl_fechado AS INT))                                 AS fechados,
    CAST(100.0 * SUM(CAST(f.fl_fechado AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS pct_fechados,
    CAST(AVG(f.horas_resolucao) AS DECIMAL(10,2))                  AS media_horas
FROM dw.fato_chamado f
JOIN dw.dim_calendario c ON c.data = f.data_abertura
GROUP BY c.ano_mes
ORDER BY c.ano_mes;

-- Mediana do tempo de resolução por mês
SELECT DISTINCT
    c.ano_mes,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.horas_resolucao)
        OVER (PARTITION BY c.ano_mes) AS mediana_horas
FROM dw.fato_chamado f
JOIN dw.dim_calendario c ON c.data = f.data_abertura
WHERE f.horas_resolucao IS NOT NULL
ORDER BY c.ano_mes;

-- Chamados por faixa de resolução (setembro)
SELECT fx.faixa, COUNT(*) AS chamados
FROM dw.fato_chamado f
JOIN dw.dim_faixa_resolucao fx ON fx.id_faixa = f.id_faixa
WHERE f.data_abertura >= '2026-09-01' AND f.data_abertura < '2026-10-01'
GROUP BY fx.faixa, fx.ordem
ORDER BY fx.ordem;
GO
