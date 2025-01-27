USE [CDMV6]
GO
/****** Object:  StoredProcedure [dbo].[CDM_RXNORM_NDC_META_BUILD]    Script Date: 4/30/2021 11:52:58 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[CDM_RXNORM_NDC_META_BUILD]
AS
BEGIN

/*
Module:
    CDM_RXNORM_NDC_META_BUILD

Purpose:
    Build i2b2.MEDICATION_METADATA table, copy to DEID, load modifier_dimension and fact count
    NOTE: named to match the TRC build procedure related to RXNORM, since the TRC and Metadata
          tables go hand in hand.

Input tables:
	RXNORM.dbo.*
	ref.RXNORM_NDC_TRC
    dbo.MEDICATION_META_ROOTS (in this DB, CDMVx)

Output Tables:
    ref.MEDICATION_METADATA (in this DB)
	ref.RXNORM_NDC_TRC

Modification History: Developed 20200930 JRC
                      20201119 Corrected error which bypassed 'MIN' and 'PIN' at ingredient level
*/

DECLARE
    @proc_name NVARCHAR(50) = 'CDM_RXNORM_NDC_META_BUILD',
    @table_name NVARCHAR(128) = N'ref.MEDICATION_METADATA'
DECLARE
    @proc_name_braced NVARCHAR(50) = dbo.BRACE_STRING(@proc_name),
    @proc_build_id BIGINT,
    @proc_row_count BIGINT,
    @row_count BIGINT,
    @sql_string NVARCHAR(MAX),
	@generation_cntr INTEGER,
	@generation_max  INTEGER,
	@rxnorm_release_date  DATE,
	@rxnorm_update_date  DATE;

/* ------------------- */
/*     Initialize      */
/* ------------------- */

BEGIN
    EXEC DROP_TABLE @table_name;
    EXEC LOG_TABLE_BUILD_START @proc_build_id OUTPUT, @proc_name, @proc_name_braced, '(proc)'

	PRINT 'Building new copy of ref.RXNORM_NDC_TRC'

EXEC CDM_RXNORM_NDC_TRC_BUILDN;

END


BEGIN
    CREATE TABLE #ROOTS
      (
      ROOT  BIGINT NULL,
      BASECODE  BIGINT NULL,
      C_HLEVEL  NUMERIC(22,0) NOT NULL,
      C_FULLNAME  VARCHAR(700) NOT NULL,
      C_NAME  VARCHAR(2000) NOT NULL,
      C_SYNONYM_CD  CHAR(1) NOT NULL,
      C_VISUALATTRIBUTES  CHAR(3) NOT NULL,
      C_TOTALNUM  NUMERIC(22,0) NULL,
      C_BASECODE  VARCHAR(50) NULL,
      C_METADATAXML  VARCHAR(MAX) NULL,
      C_FACTTABLECOLUMN  VARCHAR(50) NOT NULL,
      C_TABLENAME  VARCHAR(50) NOT NULL,
      C_COLUMNNAME  VARCHAR(50) NOT NULL,
      C_COLUMNDATATYPE  VARCHAR(50) NOT NULL,
      C_OPERATOR  VARCHAR(10) NOT NULL,
      C_DIMCODE  VARCHAR(700) NOT NULL,
      C_COMMENT  VARCHAR(MAX) NULL,
      C_TOOLTIP  VARCHAR(900) NULL,
      M_APPLIED_PATH  VARCHAR(700) NOT NULL,
      UPDATE_DATE DATETIME2(0) NULL,
      DOWNLOAD_DATE  DATETIME2(0) NULL,
      IMPORT_DATE DATETIME2(0) NULL,
      SOURCESYSTEM_CD  VARCHAR(50) NULL,
      VALUETYPE_CD  VARCHAR(50) NULL,
      M_EXCLUSION_CD  VARCHAR(25) NULL,
      FACT_COUNT  NUMERIC(38,0) NULL
      );

    /*     Identify all RXNORM root hierarchies to build out    */

    INSERT INTO #ROOTS WITH (TABLOCK)
    SELECT 0 AS ROOT, 0 AS BASECODE, M.*
    FROM dbo.MEDICATION_META_ROOTS M ORDER BY C_HLEVEL;
END

/* --------------------------------------------- */
/*   Insert INGREDIENT hierarchy into #ROOTS.    */
/* --------------------------------------------- */

BEGIN 
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      4 AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,T.SUPERTYPE_RXCUI,'\') AS C_FULLNAME,
      CONCAT(T.SUPERTYPE_TERM,' [',X.STATUS,']') AS C_NAME,
      R.C_SYNONYM_CD,
      R.C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      CONCAT('RXNORM:',T.SUPERTYPE_RXCUI) AS C_BASECODE,
      CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
      R.C_FACTTABLECOLUMN,
      --CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN 'RXNORM_NDC_TRC'      ELSE 'CONCEPT_DIMENSION' END AS 
	  R.C_TABLENAME,
      --CASE  WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN 'SUPERTYPE_RXCUI'         ELSE 'CONCEPT_PATH' END AS 
	  R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
      CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN CONCAT('RXNORM:',T.SUPERTYPE_RXCUI)
	       ELSE CONCAT(R.C_FULLNAME,T.SUPERTYPE_RXCUI,'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('Ingredient:',T.SUPERTYPE_RXCUI,' ',T.SUPERTYPE_TERM) AS C_TOOLTIP,
	  '@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
    FROM
      #ROOTS R
      JOIN (SELECT
              TRY_CONVERT(VARCHAR(15),RXCUI) AS SUPERTYPE_RXCUI,
              CAST(NAME AS VARCHAR(255)) AS SUPERTYPE_TERM
            FROM RXNORM.dbo.RXCUI
            WHERE TTY IN ('IN', 'PIN', 'MIN')
            GROUP BY TRY_CONVERT(VARCHAR(15),RXCUI), CAST(NAME AS VARCHAR(255))
           ) T ON SUBSTRING(T.SUPERTYPE_TERM,PATINDEX('%[A-Z]%',T.SUPERTYPE_TERM),1) = R.C_NAME 
      LEFT OUTER JOIN RXNORM.dbo.RXCUI X ON X.RXCUI = T.SUPERTYPE_RXCUI
    WHERE
      ((R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\INGREDIENT\%') OR (R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCPATH\INGREDIENT\%'))
        AND R.C_HLEVEL = 3;
END

/* ----------------------------------------------------------------- */
/*    Add INGREDIENT to CLINICAL DRUG relationships to #ROOTS.       */
/* ----------------------------------------------------------------- */

BEGIN
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      5 AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') AS C_FULLNAME,
      CONCAT(T.SUBTYPE_TERM,' [',X.STATUS,']') AS C_NAME,
      R.C_SYNONYM_CD,
      R.C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      T.CONCEPT_CD AS C_BASECODE,
      CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
       R.C_FACTTABLECOLUMN,
       R.C_TABLENAME,
       R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
      CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN T.CONCEPT_CD
	       ELSE CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('Ingredient:',T.SUPERTYPE_RXCUI,' ',T.SUPERTYPE_TERM) AS C_TOOLTIP,
      '@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
    FROM
      #ROOTS R
      JOIN ref.RXNORM_NDC_TRC T
        ON T.SUPERTYPE_RXCUI = SUBSTRING(R.C_BASECODE,8,20)
             AND T.SUBTYPE_TTY IN ('SBD','SCD','GPCK','BPCK','SCDC','SBDC')
      LEFT OUTER JOIN RXNORM.dbo.RXCUI X ON X.RXCUI = SUBSTRING(T.CONCEPT_CD,8,20)
    WHERE
      ((R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\INGREDIENT\%' ) OR (R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCPATH\INGREDIENT\%'  ))
        AND R.C_HLEVEL = 4;
END

/* ------------------------------------------------------ */
/*   Add CLINICAL DRUG to NDC relationships to #ROOTS.    */
/* ------------------------------------------------------ */

BEGIN
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      6 AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') AS C_FULLNAME,
      T.SUBTYPE_TERM AS C_NAME,
      R.C_SYNONYM_CD,
      'LA ' AS C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      T.CONCEPT_CD AS C_BASECODE,
      CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
       R.C_FACTTABLECOLUMN,
       R.C_TABLENAME,
       R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
      CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN T.CONCEPT_CD 
	       ELSE CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('Manufactured product:',T.SUBTYPE_RXCUI,' ',SUBSTRING(T.SUBTYPE_TERM,1,256)) AS C_TOOLTIP,
	  '@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
    FROM
      #ROOTS R
      JOIN (SELECT SUPERTYPE_RXCUI, SUPERTYPE_TERM ,SUBTYPE_RXCUI, SUBTYPE_TERM,CONCEPT_CD
            FROM ref.RXNORM_NDC_TRC 
            WHERE SUPERTYPE_TTY IN ('SBD','SCD','GPCK','BPCK','SCDC','SBDC') AND SUBTYPE_TTY = 'NDC'
            GROUP BY SUPERTYPE_RXCUI, SUPERTYPE_TERM ,SUBTYPE_RXCUI, SUBTYPE_TERM,CONCEPT_CD
           ) T ON T.SUPERTYPE_RXCUI = SUBSTRING(R.C_BASECODE,8,20)
    WHERE
       ((R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\INGREDIENT\%' ) OR (R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCPATH\INGREDIENT\%'  ))
        AND R.C_HLEVEL = 5;
END

/* ---------------------------------------------------------------------- */
/*   Build temp table in #ROOTS and copy: VACLASS to RXCUI for IN         */
/* ---------------------------------------------------------------------- */

BEGIN
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      (R.C_HLEVEL +1) AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,CAST(T.RXCUI AS VARCHAR(20)),'\') AS C_FULLNAME,
      T.RX_NAME AS C_NAME,
      R.C_SYNONYM_CD,
      'FA ' AS C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      CONCAT('RXNORM:',T.RXCUI) AS C_BASECODE, 
	  CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
      R.C_FACTTABLECOLUMN,
       R.C_TABLENAME,
       R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
       CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN CONCAT('RXNORM:',T.RXCUI)
	       ELSE CONCAT(R.C_FULLNAME,CAST(T.RXCUI AS VARCHAR(20)),'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('VA ',T.CLASS_NAME,'\Ingredient:',T.RXCUI,' ',T.RX_NAME) AS C_TOOLTIP,
      '@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
     FROM
      dbo.MEDICATION_META_ROOTS R
      JOIN (SELECT CONCAT('VACLASS:',VA_CLASS) AS VACLASS, CLASS_NAME,CAST(RXCUI AS VARCHAR(20)) AS RXCUI,TTY,RX_NAME
            FROM RXNORM.dbo.VA_CLASS_TO_RXCUI
            WHERE TTY IN ('IN', 'MIN', 'PIN')
            GROUP BY CONCAT('VACLASS:',VA_CLASS), CLASS_NAME, CAST(RXCUI AS VARCHAR(20)),TTY,RX_NAME
           ) T  ON T.VACLASS = R.C_BASECODE
   WHERE
      R.C_FULLNAME LIKE '\i2b2_RXNORM_NDC%\RXNORM_CUI\%'
        AND C_BASECODE LIKE 'VACLASS:%';
END

/* --------------------------------------------------------------- */
/*   Add VACLASS to IN to CLINICAL DRUG relationship to #ROOTS.    */
/* --------------------------------------------------------------- */

BEGIN
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      (R.C_HLEVEL +1) AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') AS C_FULLNAME,
      T.SUBTYPE_TERM AS C_NAME,
      R.C_SYNONYM_CD,
      'FA ' AS C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      T.CONCEPT_CD AS C_BASECODE,
      CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
        R.C_FACTTABLECOLUMN,
       R.C_TABLENAME,
       R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
     CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN T.CONCEPT_CD
	       ELSE CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('VA\Clinical drug:',
      SUBSTRING(T.CONCEPT_CD,8,20),' ',SUBSTRING(T.SUBTYPE_TERM,1,256)) AS C_TOOLTIP,'@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
     FROM
     #ROOTS R
     JOIN (SELECT SUPERTYPE_RXCUI,SUPERTYPE_TERM,SUBTYPE_RXCUI, SUBTYPE_TERM, CONCEPT_CD
           FROM ref.RXNORM_NDC_TRC
           WHERE
             SUPERTYPE_TTY IN ('IN', 'MIN', 'PIN')
               AND SUBTYPE_TTY IN ('SCD','GPCK','BPCK','SBD','SCDC','SBDC')
           GROUP BY
             SUPERTYPE_RXCUI, SUPERTYPE_TERM, SUBTYPE_RXCUI, SUBTYPE_TERM,CONCEPT_CD
          ) T  ON T.SUPERTYPE_RXCUI = SUBSTRING(R.C_BASECODE,8,20)
    WHERE
      R.C_FULLNAME LIKE '\i2b2_RXNORM_NDC%\RXNORM_CUI\%' 
	  AND R.C_BASECODE LIKE 'RXNORM:%';
END

/* -------------------------------------------------------------- */
/*   Add VACLASS CLINICAL DRUG to NDC relationships to #ROOTS.    */
/* -------------------------------------------------------------- */

BEGIN
    INSERT INTO #ROOTS
    SELECT
      0 AS ROOT,
      0 AS BASECODE,
      R.C_HLEVEL +1 AS C_HLEVEL,
      CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') AS C_FULLNAME,
      T.SUBTYPE_TERM AS C_NAME,
      R.C_SYNONYM_CD,
      'LA ' AS C_VISUALATTRIBUTES,
      0 AS C_TOTALNUM,
      T.CONCEPT_CD AS C_BASECODE,
      CAST(NULL AS VARCHAR(MAX)) AS C_METADATAXML,
          R.C_FACTTABLECOLUMN,
       R.C_TABLENAME,
       R.C_COLUMNNAME,
      R.C_COLUMNDATATYPE,
      R.C_OPERATOR,
      CASE WHEN R.C_FULLNAME LIKE '\i2b2_RXNORM_NDCTRC\%' THEN T.CONCEPT_CD
	       ELSE CONCAT(R.C_FULLNAME,T.SUBTYPE_RXCUI,'\') END AS C_DIMCODE,
      NULL AS C_COMMENT,
      CONCAT('Manufactured product:',T.SUBTYPE_RXCUI,' ',SUBSTRING(T.SUBTYPE_TERM,1,256)) AS C_TOOLTIP,
      '@' AS M_APPLIED_PATH,
      NULL AS UPDATE_DATE,
      NULL AS DOWNLOAD_DATE,
      NULL AS IMPORT_DATE,
      'rxnav.nlm.nih.gov' AS SOURCESYSTEM_CD,
      NULL AS VALUETYPE_CD,
      NULL AS M_EXCLUSION_CD,
      0 AS FACT_COUNT
    FROM
      #ROOTS R
      JOIN (SELECT SUPERTYPE_RXCUI, SUPERTYPE_TERM ,SUBTYPE_RXCUI, SUBTYPE_TERM,CONCEPT_CD
            FROM ref.RXNORM_NDC_TRC 
            WHERE
              SUPERTYPE_TTY IN ('SBD','SCD','GPCK','BPCK','SBDC','SCDC')
                AND SUBTYPE_TTY = 'NDC'
            GROUP BY SUPERTYPE_RXCUI, SUPERTYPE_TERM ,SUBTYPE_RXCUI, SUBTYPE_TERM,CONCEPT_CD
           ) T  ON T.SUPERTYPE_RXCUI = SUBSTRING(R.C_BASECODE,8,20)
    WHERE
      R.C_FULLNAME LIKE '\i2b2_RXNORM_NDC\RXNORM_CUI\%';
END

/* ----------------------------------------------------------------------------------------- */
/*   Build ref.MEDICATION_METADATA from #ROOTS (the coup-de-gracie moment of this proc).    */
/* ----------------------------------------------------------------------------------------- */

BEGIN
    -- NOTE: if the metadata table pre-existed, it was deleted at the start of the proc

    CREATE TABLE ref.MEDICATION_METADATA
      (
      C_HLEVEL  NUMERIC(22,0) NOT NULL,
      C_FULLNAME  VARCHAR(700) NOT NULL,
      C_NAME  VARCHAR(2000) NOT NULL,
      C_SYNONYM_CD  CHAR(1) NOT NULL,
      C_VISUALATTRIBUTES  CHAR(3) NOT NULL,
      C_TOTALNUM  NUMERIC(22,0) NULL,
      C_BASECODE  VARCHAR(50) NULL,
      C_METADATAXML  VARCHAR(MAX) NULL,
      C_FACTTABLECOLUMN  VARCHAR(50) NOT NULL,
      C_TABLENAME  VARCHAR(50) NOT NULL,
      C_COLUMNNAME  VARCHAR(50) NOT NULL,
      C_COLUMNDATATYPE  VARCHAR(50) NOT NULL,
      C_OPERATOR  VARCHAR(10) NOT NULL,
      C_DIMCODE  VARCHAR(700) NOT NULL,
      C_COMMENT  VARCHAR(MAX) NULL,
      C_TOOLTIP  VARCHAR(900) NULL,
      M_APPLIED_PATH  VARCHAR(700) NOT NULL,
      UPDATE_DATE DATETIME2(0) NULL,
      DOWNLOAD_DATE  DATETIME2(0) NULL,
      IMPORT_DATE DATETIME2(0) NULL,
      SOURCESYSTEM_CD  VARCHAR(50) NULL,
      VALUETYPE_CD  VARCHAR(50) NULL,
      M_EXCLUSION_CD  VARCHAR(25) NULL,
      FACT_COUNT  NUMERIC(38,0) NULL
      );


    -- INSERT ROWS FROM #ROOTS

    INSERT INTO ref.MEDICATION_METADATA WITH (TABLOCK)
      (
      C_HLEVEL,
      C_FULLNAME,
      C_NAME,
      C_SYNONYM_CD,
      C_VISUALATTRIBUTES,
      C_TOTALNUM,
      C_BASECODE,
      C_METADATAXML,
      C_FACTTABLECOLUMN,
      C_TABLENAME,
      C_COLUMNNAME,
      C_COLUMNDATATYPE,
      C_OPERATOR,
      C_DIMCODE,
      C_COMMENT,
      C_TOOLTIP,
      M_APPLIED_PATH,
      UPDATE_DATE,
      DOWNLOAD_DATE,
      IMPORT_DATE,
      SOURCESYSTEM_CD,
      VALUETYPE_CD,
      M_EXCLUSION_CD,
      FACT_COUNT      
      )
    SELECT
      C_HLEVEL,
      C_FULLNAME,
      C_NAME,
      C_SYNONYM_CD,
      C_VISUALATTRIBUTES,
      C_TOTALNUM,
      C_BASECODE,
      C_METADATAXML,
      C_FACTTABLECOLUMN,
      C_TABLENAME,
      C_COLUMNNAME,
      C_COLUMNDATATYPE,
      C_OPERATOR,
      C_DIMCODE,
      C_COMMENT,
      C_TOOLTIP,
      M_APPLIED_PATH,
      UPDATE_DATE,
      DOWNLOAD_DATE,
      IMPORT_DATE,
      SOURCESYSTEM_CD,
      VALUETYPE_CD,
      M_EXCLUSION_CD,
      FACT_COUNT 
    FROM
      #ROOTS;

    -- INSERT PROVENANCE ROWS

    SET @rxnorm_release_date = (SELECT MAX(RELEASE_DATE) FROM RXNORM.dbo.PROVENANCE_RXCUI);

    SET @rxnorm_update_date = (SELECT MAX(UPDATE_DATE) FROM RXNORM.dbo.PROVENANCE_RXCUI);

    INSERT INTO ref.MEDICATION_METADATA
    VALUES
      (2,'\i2b2_RXNORM_NDCTRC\PROVENANCE\','PROVENANCE','N','FH',0,'','','CONCEPT_CD','','SUPERTYPE_CNCPT','T','=','','','Provenance','@','','','','UNebraskaMC','','',0),
      (3,'\i2b2_RXNORM_NDCTRC\PROVENANCE\PUBLICATION_DATE\',CONCAT('RXNORM PUBLICATION_DATE: ',CAST(@rxnorm_release_date AS CHAR(12))),'N','LH',0,'','','CONCEPT_CD','','SUPERTYPE_CNCPT','T','=','','',CAST(@rxnorm_release_date AS CHAR(12)),'@','','','','UNebraskaMC','','',0),
      (3,'\i2b2_RXNORM_NDCTRC\PROVENANCE\METADATA_UPDATE_DATE\',CONCAT('METADATA UPDATE DATE: ',CAST(GETDATE() AS CHAR(12))),'N','LH',0,'','','CONCEPT_CD','','SUPERTYPE_CNCPT','T','=','','',CAST(@rxnorm_update_date AS CHAR(12)),'@','','','','UNebraskaMC','','',0),
	  (3,'\i2b2_RXNORM_NDCTRC\PROVENANCE\AUTHOR\','AUTHORS: Jay Pedersen, Jim Campbell','N','LH',0,'','','CONCEPT_CD','','SUPERTYPE_CNCPT','T','=','','','Jay Pedersen and Jim Campbell','@','','','','UNebraskaMC','','',0);

END

/*      Copy finished tables to DEID                         */

BEGIN

PRINT 'Copying TRC tables to DEID';

-- DELETE OLD TABLE
SET @sql_string = 'IF OBJECT_ID(''CRANE_CDM.ref.RXNORM_NDC_TRC'', ''U'') IS NOT NULL DROP TABLE CRANE_CDM.ref.RXNORM_NDC_TRC'; 
exec (@sql_string) AT DEID;
-- COPY NEW TABLE AS EMPTY
SET @sql_string = 'select top 0 * into CRANE_CDM.ref.RXNORM_NDC_TRC from GPRITSQL01.CDMV6.ref.RXNORM_NDC_TRC;';
exec (@sql_string) AT DEID;
-- COPY DATA INTO NEW TABLE
SET @sql_string = 'insert into CRANE_CDM.ref.RXNORM_NDC_TRC WITH (TABLOCK) select * from GPRITSQL01.CDMV6.ref.RXNORM_NDC_TRC with (nolock);';
exec (@sql_string) AT DEID;


-- DELETE OLD TABLE
SET @sql_string = 'IF OBJECT_ID(''BLUEHERONDATA.dbo.RXNORM_NDC_TRC'', ''U'') IS NOT NULL DROP TABLE BLUEHERONDATA.dbo.RXNORM_NDC_TRC'; 
exec (@sql_string) AT DEID;
-- COPY NEW TABLE AS EMPTY
SET @sql_string = 'select top 0 * into BLUEHERONDATA.dbo.RXNORM_NDC_TRC from GPRITSQL01.CDMV6.ref.RXNORM_NDC_TRC;';
exec (@sql_string) AT DEID;
-- COPY DATA INTO NEW TABLE
SET @sql_string = 'insert into BLUEHERONDATA.dbo.RXNORM_NDC_TRC WITH (TABLOCK) select * from GPRITSQL01.CDMV6.ref.RXNORM_NDC_TRC with (nolock);';
exec (@sql_string) AT DEID;

--Delete the table MEDICATION_METADATA from DEID.BLUEHERONMETADATA AND COPY THE NEW TABLE FROM CDMV6 to BLUEHERONMETADATA


PRINT 'Copying MEDICATION_METADATA to DEID';

-- DELETE OLD TABLE
SET @sql_string = 'IF OBJECT_ID(''BLUEHERONMETADATA.dbo.MEDICATION_METADATA'', ''U'') IS NOT NULL DROP TABLE BLUEHERONMETADATA.dbo.MEDICATION_METADATA'; 
exec (@sql_string) AT DEID;
-- COPY NEW TABLE AS EMPTY
SET @sql_string = 'select top 0 * into BLUEHERONMETADATA.dbo.MEDICATION_METADATA from GPRITSQL01.CDMV6.ref.MEDICATION_METADATA;';
exec (@sql_string) AT DEID;
-- COPY DATA INTO NEW TABLE
SET @sql_string = 'insert into BLUEHERONMETADATA.dbo.MEDICATION_METADATA WITH (TABLOCK) select * from GPRITSQL01.CDMV6.ref.MEDICATION_METADATA with (nolock);';
exec (@sql_string) AT DEID;

--load modifier_dimension
--DECLARE @sql_string NVARCHAR(MAX)
PRINT 'LOAD_MODIFIER_DIM';

SET @sql_string = 'blueherondata.dbo.load_modifier_dim ''BLUEHERONMETADATA'',''BLUEHERONDATA''';
exec (@sql_string) AT DEID;

--DECLARE @sql_string NVARCHAR(MAX) --Delete old C_FULLNAMEs from concept_dimension and then load new concept_dimension

SET @sql_string = 'DELETE FROM [BlueheronData].[dbo].[CONCEPT_DIMENSION]   WHERE CONCEPT_PATH LIKE ''\i2b2_RXNORM_NDCTRC\%''';
exec (@sql_string) AT DEID;

SET @sql_string = 'DELETE FROM [BlueheronData].[dbo].[CONCEPT_DIMENSION]   WHERE CONCEPT_PATH LIKE ''\i2b2_RXNORM_NDCPATH\%''';
exec (@sql_string) AT DEID;

SET @sql_string = 'DELETE FROM [BlueheronData].[dbo].[CONCEPT_DIMENSION]   WHERE CONCEPT_PATH LIKE ''\i2b2_RXNORM_NDC\PROVENANCE\%''';
exec (@sql_string) AT DEID;

--load concept-dimension 

PRINT 'LOAD_CONCEPT_DIM';

SET @sql_string = 'BLUEHERONDATA.dbo.load_concept_dim ''BLUEHERONMETADATA.dbo.MEDICATION_METADATA'',''BLUEHERONDATA''';
exec (@sql_string) AT DEID;

 --run fact counting on the new metadata table                                                                      

 PRINT 'Run FACT_COUNT';

SET @sql_string = 'BLUEHERONDATA.dbo.fact_count ''BLUEHERONMETADATA.dbo.MEDICATION_METADATA'',''RXNORM_NDC_TRC'',''1'''
exec (@sql_string) AT DEID;

PRINT 'Update TABLE_ACCESS with stats for fact counts'

--DECLARE  @sql_string NVARCHAR(MAX)

SET @sql_string = (SELECT CONCAT('Medications [',COUNT (*)/1000000,'M facts,', COUNT (DISTINCT PATIENT_NUM)/1000,'K patients]')  --Insert into DEID.BULEUERONMETADATA.dbo.SNOMEDCT_METADATA
FROM DEID.BLUEHERONDATA.dbo.OBSERVATION_FACT F
WHERE ((CONCEPT_CD LIKE 'RXNORM:%') OR (CONCEPT_CD LIKE 'NDC:%')) 
AND MODIFIER_CD LIKE 'RX%' ) ;


UPDATE DEID.BLUEHERONMETADATA.dbo.TABLE_ACCESS SET C_NAME = (@sql_string)
WHERE C_TABLE_NAME = 'MEDICATION_METADATA' ;

UPDATE DEID.CRANEUSERSMETA.dbo.TABLE_ACCESS SET C_NAME = (@sql_string)                                                         
	WHERE C_TABLE_NAME = 'MEDICATION_METADATA' ;

 
PRINT 'Generate validation counts by ingredient and VA Class for patient count with data' 

SELECT CONCAT('<<Ingredient RXNORM:2551 Ciprofloxacin Patient numbers:',TRY_CONVERT(VARCHAR(10),COUNT(DISTINCT PATIENT_NUM)),' Fact count:', TRY_CONVERT(VARCHAR(10),COUNT (*)))
FROM DEID.BLUEHERONDATA.dbo.OBSERVATION_FACT
WHERE CONCEPT_CD IN (SELECT DISTINCT CONCEPT_CD
                     FROM DEID.BLUEHERONDATA.dbo.RXNORM_NDC_TRC
                     WHERE SUPERTYPE_RXCUI = '2551');

SELECT CONCAT('<<VACLASS:AM400 Quinolones Patient numbers:',TRY_CONVERT(VARCHAR(10),COUNT(DISTINCT PATIENT_NUM)),' Fact count:', TRY_CONVERT(VARCHAR(10),COUNT (*)))
FROM DEID.BLUEHERONDATA.dbo.OBSERVATION_FACT
WHERE CONCEPT_CD IN (SELECT DISTINCT CONCEPT_CD
                     FROM DEID.BLUEHERONDATA.dbo.RXNORM_NDC_TRC
                     WHERE SUPERTYPE_CNCPT = 'VACLASS:AM400');


END


/* ----------------- */
/*     Terminate     */
/* ----------------- */

BEGIN
    EXEC LOG_TABLE_BUILD_END @proc_build_id, @proc_row_count
    RETURN 0;
END

END