-- 01 - Banco, schemas e tabelas de controle

IF DB_ID('CHAMADOS311') IS NULL
    CREATE DATABASE CHAMADOS311;
GO

ALTER DATABASE CHAMADOS311 SET RECOVERY SIMPLE;
GO

USE CHAMADOS311;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('ctl') IS NULL EXEC('CREATE SCHEMA ctl');
GO

IF OBJECT_ID('ctl.parametros') IS NULL
    CREATE TABLE ctl.parametros (
        chave VARCHAR(50)   NOT NULL PRIMARY KEY,
        valor NVARCHAR(500) NOT NULL
    );
GO

IF NOT EXISTS (SELECT 1 FROM ctl.parametros WHERE chave = 'PASTA_DADOS')
    INSERT INTO ctl.parametros (chave, valor)
    VALUES ('PASTA_DADOS', N'C:\Users\rapha\OneDrive\Documentos\Documentação Trabalho\Projetos\Projeto - Reclamações\dados');
GO

IF OBJECT_ID('ctl.arquivos_carga') IS NULL
    CREATE TABLE ctl.arquivos_carga (
        id_carga           INT IDENTITY(1,1) PRIMARY KEY,
        nome_arquivo       VARCHAR(100)   NOT NULL,
        mes_ref            CHAR(7)        NOT NULL,
        dt_inicio          DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
        dt_fim             DATETIME2(0)   NULL,
        status             VARCHAR(10)    NOT NULL,
        linhas_arquivo     INT            NULL,
        linhas_carregadas  INT            NULL,
        linhas_rejeitadas  INT            NULL,
        mensagem           NVARCHAR(4000) NULL
    );
GO

IF OBJECT_ID('ctl.log_erros') IS NULL
    CREATE TABLE ctl.log_erros (
        id_erro      INT IDENTITY(1,1) PRIMARY KEY,
        dt_erro      DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
        origem       VARCHAR(100)   NOT NULL,
        nome_arquivo VARCHAR(100)   NULL,
        numero       INT            NULL,
        linha        INT            NULL,
        mensagem     NVARCHAR(4000) NULL
    );
GO

CREATE OR ALTER PROCEDURE ctl.sp_registrar_erro
    @origem       VARCHAR(100),
    @nome_arquivo VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO ctl.log_erros (origem, nome_arquivo, numero, linha, mensagem)
    VALUES (@origem, @nome_arquivo, ERROR_NUMBER(), ERROR_LINE(), ERROR_MESSAGE());
END;
GO
