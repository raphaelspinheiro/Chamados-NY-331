-- 03 - Dimensões e fato

USE CHAMADOS311;
GO

/* ---------- Calendário (2024 a 2027) ---------- */
IF OBJECT_ID('dw.dim_calendario') IS NULL
BEGIN
    CREATE TABLE dw.dim_calendario (
        data          DATE        NOT NULL PRIMARY KEY,
        ano           SMALLINT    NOT NULL,
        mes           TINYINT     NOT NULL,
        nome_mes      VARCHAR(10) NOT NULL,
        ano_mes       CHAR(7)     NOT NULL,
        dia           TINYINT     NOT NULL,
        dia_semana    TINYINT     NOT NULL,   -- 1 = domingo
        nome_dia      VARCHAR(10) NOT NULL,
        fl_fim_semana BIT         NOT NULL,
        inicio_semana DATE        NOT NULL
    );

    WITH datas AS (
        SELECT CAST('2024-01-01' AS DATE) AS data
        UNION ALL
        SELECT DATEADD(DAY, 1, data) FROM datas WHERE data < '2027-12-31'
    ), base AS (
        -- 07/01/1900 foi domingo: o cálculo não depende do idioma do servidor
        SELECT data, DATEDIFF(DAY, '19000107', data) % 7 + 1 AS dia_semana
        FROM datas
    )
    INSERT INTO dw.dim_calendario
    SELECT
        data,
        YEAR(data),
        MONTH(data),
        CHOOSE(MONTH(data), 'Janeiro','Fevereiro','Março','Abril','Maio','Junho',
                            'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'),
        CONVERT(CHAR(7), data, 126),
        DAY(data),
        dia_semana,
        CHOOSE(dia_semana, 'Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'),
        CASE WHEN dia_semana IN (1, 7) THEN 1 ELSE 0 END,
        DATEADD(DAY, 1 - dia_semana, data)
    FROM base
    OPTION (MAXRECURSION 0);
END;
GO

/* ---------- Hora do dia ---------- */
IF OBJECT_ID('dw.dim_hora') IS NULL
BEGIN
    CREATE TABLE dw.dim_hora (
        hora    TINYINT     NOT NULL PRIMARY KEY,
        rotulo  CHAR(3)     NOT NULL,
        periodo VARCHAR(10) NOT NULL
    );

    INSERT INTO dw.dim_hora
    SELECT
        n,
        RIGHT('0' + CAST(n AS VARCHAR(2)), 2) + 'h',
        CASE WHEN n < 6 THEN 'Madrugada' WHEN n < 12 THEN 'Manhã'
             WHEN n < 18 THEN 'Tarde' ELSE 'Noite' END
    FROM (SELECT TOP (24) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
          FROM sys.all_objects) h;
END;
GO

/* ---------- Faixas de tempo de resolução ---------- */
IF OBJECT_ID('dw.dim_faixa_resolucao') IS NULL
BEGIN
    CREATE TABLE dw.dim_faixa_resolucao (
        id_faixa TINYINT     NOT NULL PRIMARY KEY,
        faixa    VARCHAR(30) NOT NULL,
        ordem    TINYINT     NOT NULL
    );

    INSERT INTO dw.dim_faixa_resolucao VALUES
        (1, 'Até 1h',             1),
        (2, '1h a 24h',           2),
        (3, '1 a 7 dias',         3),
        (4, '7 a 30 dias',        4),
        (5, 'Mais de 30 dias',    5),
        (0, 'Em aberto',          6),
        (9, 'Data inconsistente', 7);
END;
GO

/* ---------- Órgão responsável ---------- */
IF OBJECT_ID('dw.dim_agencia') IS NULL
    CREATE TABLE dw.dim_agencia (
        sk_agencia  INT IDENTITY(1,1) PRIMARY KEY,
        agency      VARCHAR(20)  NOT NULL UNIQUE,
        agency_name VARCHAR(150) NOT NULL
    );
GO

/* ---------- Tipo de problema ---------- */
IF OBJECT_ID('dw.dim_tipo') IS NULL
    CREATE TABLE dw.dim_tipo (
        sk_tipo        INT IDENTITY(1,1) PRIMARY KEY,
        complaint_type VARCHAR(150) NOT NULL,
        descriptor     VARCHAR(200) NOT NULL,
        grupo          VARCHAR(150) NOT NULL,   -- "Noise - Residential" -> NOISE
        CONSTRAINT uq_dim_tipo UNIQUE (complaint_type, descriptor)
    );
GO

/* ---------- Fato: 1 linha por chamado ---------- */
IF OBJECT_ID('dw.fato_chamado') IS NULL
BEGIN
    CREATE TABLE dw.fato_chamado (
        unique_key             BIGINT        NOT NULL,
        data_abertura          DATE          NOT NULL,
        hora_abertura          TINYINT       NOT NULL,
        dt_abertura            DATETIME2(0)  NOT NULL,
        dt_fechamento          DATETIME2(0)  NULL,
        data_fechamento        DATE          NULL,
        dt_ultima_acao         DATETIME2(0)  NULL,
        status                 VARCHAR(30)   NOT NULL,
        fl_fechado             BIT           NOT NULL,
        horas_resolucao        DECIMAL(10,2) NULL,
        id_faixa               TINYINT       NOT NULL,
        sk_agencia             INT           NOT NULL,
        sk_tipo                INT           NOT NULL,
        canal                  VARCHAR(30)   NOT NULL,
        borough                VARCHAR(30)   NOT NULL,
        community_board        VARCHAR(50)   NULL,
        incident_zip           VARCHAR(20)   NULL,
        location_type          VARCHAR(150)  NULL,
        resolution_description VARCHAR(4000) NULL,
        latitude               DECIMAL(9,6)  NULL,
        longitude              DECIMAL(9,6)  NULL,
        CONSTRAINT pk_fato_chamado PRIMARY KEY NONCLUSTERED (unique_key),
        CONSTRAINT fk_fato_calendario FOREIGN KEY (data_abertura) REFERENCES dw.dim_calendario (data),
        CONSTRAINT fk_fato_hora       FOREIGN KEY (hora_abertura) REFERENCES dw.dim_hora (hora),
        CONSTRAINT fk_fato_faixa      FOREIGN KEY (id_faixa)      REFERENCES dw.dim_faixa_resolucao (id_faixa),
        CONSTRAINT fk_fato_agencia    FOREIGN KEY (sk_agencia)    REFERENCES dw.dim_agencia (sk_agencia),
        CONSTRAINT fk_fato_tipo       FOREIGN KEY (sk_tipo)       REFERENCES dw.dim_tipo (sk_tipo)
    );

    -- Índice pela data: a carga apaga e regrava um mês inteiro
    CREATE CLUSTERED INDEX ix_fato_chamado_data ON dw.fato_chamado (data_abertura);
END;
GO
