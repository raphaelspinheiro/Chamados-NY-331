-- 02 - Staging: cópia do CSV, tudo como texto

USE CHAMADOS311;
GO

IF OBJECT_ID('stg.chamados_311') IS NOT NULL
    DROP TABLE stg.chamados_311;
GO

-- Mesma ordem de colunas do CSV gerado pelo Python
CREATE TABLE stg.chamados_311 (
    unique_key                     VARCHAR(20),
    created_date                   VARCHAR(30),
    closed_date                    VARCHAR(30),
    due_date                       VARCHAR(30),
    resolution_action_updated_date VARCHAR(30),
    status                         VARCHAR(30),
    agency                         VARCHAR(20),
    agency_name                    VARCHAR(150),
    complaint_type                 VARCHAR(150),
    descriptor                     VARCHAR(200),
    location_type                  VARCHAR(150),
    open_data_channel_type         VARCHAR(30),
    borough                        VARCHAR(30),
    city                           VARCHAR(100),
    incident_zip                   VARCHAR(20),
    community_board                VARCHAR(50),
    resolution_description         VARCHAR(4000),
    latitude                       VARCHAR(30),
    longitude                      VARCHAR(30)
);
GO
