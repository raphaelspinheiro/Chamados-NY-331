-- 04 - Procedures de carga (BULK INSERT) e tratamento

USE CHAMADOS311;
GO

/* ---------- Tratamento: staging -> dimensões e fato ---------- */
CREATE OR ALTER PROCEDURE dw.sp_tratar_chamados
    @mes_ref           CHAR(7),
    @linhas_carregadas INT OUTPUT,
    @linhas_rejeitadas INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ini DATE = CAST(@mes_ref + '-01' AS DATE);
    DECLARE @fim DATE = DATEADD(MONTH, 1, @ini);

    -- 1) Conversão de tipos e limpeza
    DROP TABLE IF EXISTS #base;

    SELECT
        TRY_CAST(unique_key AS BIGINT)                                                  AS unique_key,
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(created_date)), ''), 126)          AS dt_abertura,
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(closed_date)), ''), 126)           AS dt_fechamento,
        TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(resolution_action_updated_date)), ''), 126) AS dt_ultima_acao,
        ISNULL(NULLIF(LTRIM(RTRIM(status)), ''), 'Unspecified')                         AS status,
        ISNULL(NULLIF(UPPER(LTRIM(RTRIM(agency))), ''), 'N/I')                          AS agency,
        ISNULL(NULLIF(LTRIM(RTRIM(agency_name)), ''), 'Não informado')                  AS agency_name,
        ISNULL(NULLIF(LTRIM(RTRIM(complaint_type)), ''), 'N/I')                         AS complaint_type,
        ISNULL(NULLIF(LTRIM(RTRIM(descriptor)), ''), 'N/I')                             AS descriptor,
        ISNULL(NULLIF(UPPER(LTRIM(RTRIM(open_data_channel_type))), ''), 'UNKNOWN')      AS canal,
        ISNULL(NULLIF(UPPER(LTRIM(RTRIM(borough))), ''), 'UNSPECIFIED')                 AS borough,
        NULLIF(LTRIM(RTRIM(community_board)), '')                                       AS community_board,
        NULLIF(LTRIM(RTRIM(incident_zip)), '')                                          AS incident_zip,
        NULLIF(LTRIM(RTRIM(location_type)), '')                                         AS location_type,
        NULLIF(LTRIM(RTRIM(resolution_description)), '')                                AS resolution_description,
        TRY_CAST(NULLIF(latitude, '')  AS DECIMAL(9,6))                                 AS latitude,
        TRY_CAST(NULLIF(longitude, '') AS DECIMAL(9,6))                                 AS longitude
    INTO #base
    FROM stg.chamados_311;

    -- 2) Linhas válidas do mês, sem duplicatas (fica a versão com a última ação mais recente)
    DROP TABLE IF EXISTS #valida;

    SELECT *
    INTO #valida
    FROM (
        SELECT b.*,
               ROW_NUMBER() OVER (PARTITION BY b.unique_key ORDER BY b.dt_ultima_acao DESC) AS rn
        FROM #base b
        WHERE b.unique_key IS NOT NULL
          AND b.dt_abertura >= @ini
          AND b.dt_abertura <  @fim
    ) x
    WHERE rn = 1;

    SET @linhas_rejeitadas = (SELECT COUNT(*) FROM #base) - (SELECT COUNT(*) FROM #valida);

    BEGIN TRANSACTION;

    -- 3) Dimensões
    MERGE dw.dim_agencia AS d
    USING (
        SELECT agency, MAX(agency_name) AS agency_name
        FROM #valida
        GROUP BY agency
    ) AS s
    ON d.agency = s.agency
    WHEN MATCHED AND d.agency_name <> s.agency_name THEN
        UPDATE SET agency_name = s.agency_name
    WHEN NOT MATCHED THEN
        INSERT (agency, agency_name) VALUES (s.agency, s.agency_name);

    -- "PLUMBING" e "Plumbing" viram um tipo só
    MERGE dw.dim_tipo AS d
    USING (
        SELECT MIN(complaint_type) AS complaint_type,
               MIN(descriptor)     AS descriptor
        FROM #valida
        GROUP BY UPPER(complaint_type), UPPER(descriptor)
    ) AS s
    ON d.complaint_type = s.complaint_type AND d.descriptor = s.descriptor
    WHEN NOT MATCHED THEN
        INSERT (complaint_type, descriptor, grupo)
        VALUES (
            s.complaint_type,
            s.descriptor,
            UPPER(LTRIM(RTRIM(
                CASE WHEN CHARINDEX(' - ', s.complaint_type) > 0
                     THEN LEFT(s.complaint_type, CHARINDEX(' - ', s.complaint_type) - 1)
                     ELSE s.complaint_type END)))
        );

    -- 4) Fato: apaga o mês e grava de novo (rodar duas vezes não duplica)
    DELETE FROM dw.fato_chamado
    WHERE data_abertura >= @ini AND data_abertura < @fim;

    INSERT INTO dw.fato_chamado (
        unique_key, data_abertura, hora_abertura, dt_abertura, dt_fechamento, data_fechamento,
        dt_ultima_acao, status, fl_fechado, horas_resolucao, id_faixa, sk_agencia, sk_tipo,
        canal, borough, community_board, incident_zip, location_type, resolution_description,
        latitude, longitude
    )
    SELECT
        v.unique_key,
        CAST(v.dt_abertura AS DATE),
        DATEPART(HOUR, v.dt_abertura),
        v.dt_abertura,
        v.dt_fechamento,
        CAST(v.dt_fechamento AS DATE),
        v.dt_ultima_acao,
        v.status,
        c.fl_fechado,
        c.horas,
        CASE WHEN c.fl_fechado = 0     THEN 0      -- em aberto
             WHEN c.segundos IS NULL   THEN 9      -- fechou antes de abrir
             WHEN c.segundos <= 3600   THEN 1
             WHEN c.segundos <= 86400  THEN 2
             WHEN c.segundos <= 604800 THEN 3
             WHEN c.segundos <= 2592000 THEN 4
             ELSE 5 END,
        a.sk_agencia,
        t.sk_tipo,
        v.canal,
        v.borough,
        v.community_board,
        v.incident_zip,
        v.location_type,
        v.resolution_description,
        v.latitude,
        v.longitude
    FROM #valida v
    JOIN dw.dim_agencia a
      ON a.agency = v.agency
    JOIN dw.dim_tipo t
      ON t.complaint_type = v.complaint_type
     AND t.descriptor     = v.descriptor
    CROSS APPLY (
        SELECT
            CAST(CASE WHEN v.status = 'Closed' AND v.dt_fechamento IS NOT NULL
                      THEN 1 ELSE 0 END AS BIT) AS fl_fechado,
            CASE WHEN v.status = 'Closed' AND v.dt_fechamento >= v.dt_abertura
                 THEN DATEDIFF(SECOND, v.dt_abertura, v.dt_fechamento)
            END AS segundos
    ) c0
    CROSS APPLY (
        SELECT c0.fl_fechado,
               c0.segundos,
               CAST(c0.segundos / 3600.0 AS DECIMAL(10,2)) AS horas
    ) c;

    SET @linhas_carregadas = @@ROWCOUNT;

    COMMIT TRANSACTION;
END;
GO

/* ---------- Carga de um arquivo ----------
   Retorno: 0 = OK | 1 = ERRO | 2 = IGNORADO */
CREATE OR ALTER PROCEDURE dw.sp_carga_arquivo
    @nome_arquivo VARCHAR(100),
    @forcar       BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @mes_ref   CHAR(7)       = SUBSTRING(@nome_arquivo, 14, 7);   -- chamados_311_AAAA-MM.csv
    DECLARE @mes_atual CHAR(7)       = CONVERT(CHAR(7), GETDATE(), 126);
    DECLARE @pasta     NVARCHAR(500) = (SELECT valor FROM ctl.parametros WHERE chave = 'PASTA_DADOS');
    DECLARE @id INT, @sql NVARCHAR(MAX), @linhas_arquivo INT, @carregadas INT, @rejeitadas INT;

    IF @nome_arquivo NOT LIKE 'chamados[_]311[_]____-__.csv'
       OR TRY_CAST(@mes_ref + '-01' AS DATE) IS NULL
    BEGIN
        RAISERROR('Nome de arquivo fora do padrão: %s', 16, 1, @nome_arquivo);
        RETURN 1;
    END;

    -- Mês fechado já carregado não entra de novo. O mês atual sempre é recarregado.
    IF @forcar = 0
       AND @mes_ref < @mes_atual
       AND EXISTS (SELECT 1 FROM ctl.arquivos_carga
                   WHERE nome_arquivo = @nome_arquivo AND status = 'OK')
    BEGIN
        PRINT @nome_arquivo + ' já carregado, ignorado';
        RETURN 2;
    END;

    INSERT INTO ctl.arquivos_carga (nome_arquivo, mes_ref, status)
    VALUES (@nome_arquivo, @mes_ref, 'EM CARGA');
    SET @id = SCOPE_IDENTITY();

    BEGIN TRY
        TRUNCATE TABLE stg.chamados_311;

        SET @sql = N'BULK INSERT stg.chamados_311
            FROM N''' + REPLACE(@pasta + N'\' + @nome_arquivo, N'''', N'''''') + N'''
            WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'',
                  FIELDQUOTE = ''"'', ROWTERMINATOR = ''0x0a'', TABLOCK);';
        EXEC sp_executesql @sql;

        SELECT @linhas_arquivo = COUNT(*) FROM stg.chamados_311;

        EXEC dw.sp_tratar_chamados @mes_ref, @carregadas OUTPUT, @rejeitadas OUTPUT;

        UPDATE ctl.arquivos_carga
        SET dt_fim            = SYSDATETIME(),
            status            = 'OK',
            linhas_arquivo    = @linhas_arquivo,
            linhas_carregadas = @carregadas,
            linhas_rejeitadas = @rejeitadas
        WHERE id_carga = @id;

        PRINT @nome_arquivo + ' carregado: ' + CAST(@carregadas AS VARCHAR(10)) + ' linhas';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        EXEC ctl.sp_registrar_erro 'dw.sp_carga_arquivo', @nome_arquivo;

        UPDATE ctl.arquivos_carga
        SET dt_fim   = SYSDATETIME(),
            status   = 'ERRO',
            mensagem = ERROR_MESSAGE()
        WHERE id_carga = @id;

        PRINT @nome_arquivo + ' com erro: ' + ERROR_MESSAGE();
        RETURN 1;
    END CATCH;
END;
GO

/* ---------- Carga de todos os arquivos da pasta ---------- */
CREATE OR ALTER PROCEDURE dw.sp_carga_completa
    @forcar BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pasta NVARCHAR(500) = (SELECT valor FROM ctl.parametros WHERE chave = 'PASTA_DADOS');
    DECLARE @arquivo VARCHAR(100), @ret INT;
    DECLARE @ok INT = 0, @ignorados INT = 0, @erros INT = 0;

    DROP TABLE IF EXISTS #arquivos;
    CREATE TABLE #arquivos (nome NVARCHAR(512), profundidade INT, eh_arquivo BIT);

    INSERT INTO #arquivos
    EXEC master.sys.xp_dirtree @pasta, 1, 1;

    DECLARE c_arquivos CURSOR LOCAL FAST_FORWARD FOR
        SELECT nome
        FROM #arquivos
        WHERE eh_arquivo = 1
          AND nome LIKE 'chamados[_]311[_]____-__.csv'
        ORDER BY nome;

    OPEN c_arquivos;
    FETCH NEXT FROM c_arquivos INTO @arquivo;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC @ret = dw.sp_carga_arquivo @arquivo, @forcar;

        IF @ret = 0      SET @ok += 1;
        ELSE IF @ret = 2 SET @ignorados += 1;
        ELSE             SET @erros += 1;

        FETCH NEXT FROM c_arquivos INTO @arquivo;
    END;

    CLOSE c_arquivos;
    DEALLOCATE c_arquivos;

    SELECT @ok AS carregados, @ignorados AS ignorados, @erros AS com_erro;
END;
GO
