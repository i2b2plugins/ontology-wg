USE [BlueheronData]
GO
/****** Object:  StoredProcedure [dbo].[FACT_COUNT]    Script Date: 4/30/2021 11:56:59 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[FACT_COUNT]
  @metadata_table_name as NVARCHAR(256),
  @trc_table_name as NVARCHAR(256) = NULL,
  @update_table_access as BIT = 0
AS
BEGIN

/*
Module:
    FACT_COUNT

Purpose:
    Fact count a metadata table, using either the C_FULLNAME paths to determine subsumed codes
    or using a TRC transitive closure table.

    This is meant to be the most generic fact-counting procedure, it should be used in most cases.

    NOTE: There are specialty metadata tables like PROVIDERS metadata where the "FACT COUNT" relates
          to the PROVIDER_ID attribute instead of CONCEPT_CD.  These specialty fact-counting
          cases are not directly supported by this procedure and require their own specialty
          fact counting procedures.  Examples of these specialty fact counting procedures are
          FACT_COUNT_PROVIDERS, FACT_COUNT_LOCATION and FACT_COUNT_ENC_PAYER.

Assumptions:
    Each metadata row where M_APPLIED_PATH='@' has a C_BASECODE value which
    exists in the TRC table.

Arguments:
  @metadata_table_name NVARCHAR(256), -- e.g. 'CraneUsersMeta.dbo.UNMC_DEMO'
  @trc_table_name NVARCHAR(256), e.g. 'BlueheronData.dbo.LOINC_TRC' or NULL if none
  @update_table_access BIT, e.g. 0 for false, updates all rows in TABLE_ACCESS for the target table
                            using the C_TABLE_CD, C_FULLNAME values to drive the update of C_NAME

Output Tables:
    Metadata table -- updated, FACT_COUNT, C_TOTALNUM, C_NAME columns updated
    TABLE_ACCESS -- updated if @update_table_access=1

Input Tables:
    Metadata table
    Fact table
    TRC table -- if @trc_table_name is non-empty string (not NULL and not '')
    TABLE_ACCESS -- if @update_table_access=1

NOTES:
    The metadata tables typically have relatively low numbers of concepts and fullnames,
    but may have hundreds of millions of facts that match those concept codes.

    Consider metadata tables with multiple navigation folders (multiple TABLE_CD values, eg: LOINC).
    The fact-count the table is still done on the TABLENAME basis and not the TABLE_CD basis.
    Why?  ALL paths are accounted for when processing all rows in the table, regardless of
    which TABLE_CD associated with each path.

Example with TRC table:
    EXEC FACT_COUNT N'BlueheronMetadata.dbo.SNOMEDCT_METADATA', N'BlueheronData.dbo.SNOMEDCT_TRC', N'\i2b2_SNOMEDCT_CONDITIONS\', 1, N'UNMC_SNOMED_CONDITIONS'

Example w/o TRC table:
    EXEC FACT_COUNT N'CraneUsersMeta.dbo.UNMC_DEMO', NULL, N'\i2b2\Demographics\', 1, N'unmc_demographics'

Author: 2020 Jay Pedersen University of Nebraska Medical Center 
*/

DECLARE
    @proc_name NVARCHAR(32) = N'FACT_COUNT';
DECLARE
    @proc_name_braced NVARCHAR(32) = dbo.BRACE_STRING(@proc_name),
    @has_trc_table BIT,
    @m_applied_path NVARCHAR(MAX),
    @proc_build_id BIGINT,
    @proc_row_count BIGINT,
    @row_count BIGINT,
    @fact_count BIGINT,
    @patient_count BIGINT,
    @c_name VARCHAR(2000),
    @table_cd VARCHAR(50),
    @md_table_name NVARCHAR(128),
    @fullname VARCHAR(700),
    @sql_string NVARCHAR(MAX),
    @s NVARCHAR(MAX),
    @log_msg as NVARCHAR(64);
DECLARE
    @metadata_db_name NVARCHAR(128),
    @metadata_db_prefix NVARCHAR(128),
    @trc_db_name NVARCHAR(128),
    @trc_db_prefix NVARCHAR(128);

/* ------------------- */
/*     Initialize      */
/* ------------------- */

BEGIN
    EXEC LOG_TABLE_BUILD_START @proc_build_id OUTPUT, @proc_name, @proc_name_braced, N'(proc)';
    -- Determine database name for metadata table and trc table.  Needed for index existence checking.
    SELECT @metadata_db_name = parsename(@metadata_table_name, 3);
    SET @metadata_db_prefix = CASE when @metadata_db_name IS NULL then '' else CONCAT(@metadata_db_name, '.') END; -- e.g. 'BlueheronMetadata.' or ''
    SET @md_table_name = parsename(@metadata_table_name, 1); -- object name, e.g. LABS_METADATA for blueheronmetadata.dbo.LABS_METADATA
    SET @has_trc_table = CASE when @trc_table_name IS NULL then 0 when len(ltrim(rtrim(@trc_table_name))) = 0 then 0 else 1 END;
    if @has_trc_table = 1
    BEGIN
        SELECT @trc_db_name = parsename(@trc_table_name, 3);
        SET @trc_db_prefix = CASE when @trc_db_name IS NULL then '' else CONCAT(@trc_db_name, '.') END;
    END
END

/*
Check for missing indexes on Metadata table needed for fact-counting, including the TRC table

Indexes on metadata table which are desired:

CREATE INDEX FULLNAME_IDX ON <table>(C_FULLNAME)
CREATE INDEX HLEVEL_IDX ON <table>(C_HLEVEL)
CREATE INDEX MAPATH_IDX ON <table>(M_APPLIED_PATH)
CREATE INDEX VISATR_IDX ON <table>(C_VISUALATTRIBUTES)
CREATE INDEX BASECODE_FULLNAME_IDX ON <table>(C_BASECODE, C_FULLNAME)
CREATE INDEX COVERING_FULLNAME_IDX ON <table>(C_FULLNAME) INCLUDE (C_BASECODE)

if TRC then theses indexes are expected on TRC table:

CREATE INDEX COVERING_CONCEPT_IDX ON <trc-table>(CONCEPT_CD) INCLUDE ([SUPERTYPE_CNCPT])
*/

BEGIN
    SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''FULLNAME_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX FULLNAME_IDX ON ' + @metadata_table_name + N'(C_FULLNAME)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:fullname)', @row_count OUTPUT;

   SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''HLEVEL_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX HLEVEL_IDX ON ' + @metadata_table_name + N'(C_HLEVEL)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:hlevel)', @row_count OUTPUT;

   SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''MAPATH_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX MAPATH_IDX ON ' + @metadata_table_name + N'(M_APPLIED_PATH)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:mapath)', @row_count OUTPUT;

   SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''VISATR_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX VISATR_IDX ON ' + @metadata_table_name + N'(C_VISUALATTRIBUTES)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:visatr)', @row_count OUTPUT;

    SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''BASECODE_FULLNAME_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX BASECODE_FULLNAME_IDX ON ' + @metadata_table_name + N'(C_BASECODE, C_FULLNAME)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:basecode_fullname)', @row_count OUTPUT;

    SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @metadata_db_prefix + N'sys.indexes WHERE name = ''COVERING_FULLNAME_IDX'' AND object_id = OBJECT_ID(''' + @metadata_table_name + N'''))
CREATE INDEX COVERING_FULLNAME_IDX ON ' + @metadata_table_name + N'(C_FULLNAME) INCLUDE (C_BASECODE)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(index:covering_fullname)', @row_count OUTPUT;

    if @has_trc_table = 1 -- TRC table
    BEGIN
        SET @sql_string = N'
IF NOT EXISTS(SELECT * FROM ' + @trc_db_prefix + N'sys.indexes WHERE name = ''COVERING_CONCEPT_IDX'' AND object_id = OBJECT_ID(''' + @trc_table_name + N'''))
CREATE INDEX COVERING_CONCEPT_IDX ON ' + @trc_table_name + N'(CONCEPT_CD) INCLUDE (SUPERTYPE_CNCPT)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(covering_concept)', @row_count OUTPUT;
    END

END

/* ---------------------------------- */
/*    Set all fact counts to zero.    */
/* ---------------------------------- */

BEGIN
    SET @sql_string = N'UPDATE ' + @metadata_table_name + N' set FACT_COUNT = 0, C_TOTALNUM = 0 where M_APPLIED_PATH=''@''';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(zero-counts)', @row_count OUTPUT;
END

/* ----------------------------------------------------------------------------------------------- */
/*    The following defines a set of temp tables used in fact counting.  The idea is to reduce     */
/*    the overall size of any one temp table.  This resolved performance issues relating to        */
/*    fact counting things like labs with hundreds of millions of matching facts.  Joining the     */
/*    metadata table directly to the fact table and performing group by operations becomes         */
/*    unworkable as the size of the number of matches moves to hundreds of millions or billions    */
/*    of rows.                                                                                     */
/*                                                                                                 */
/*    This scheme avoids that type of joining operation.                                           */
/*                                                                                                 */
/*    We maintain a table that lists the CONCEPT_CD values associated with each C_FULLNAME         */
/*    (#FULLNAME_TO_CONCEPT).                                                                    */
/*                                                                                                 */
/*    To count the facts associated with C_FULLNAME values, we create a table with the fact        */
/*    counts on a per-CONCEPT_CD basis (#CONCEPT_TO_FACTCOUNT).  This is not a large table       */
/*    because there is a single count value stored for each distinct CONCEPT_CD.  To determine     */
/*    the fact count for a C_FULLNAME, we sum the fact counts for all its associated codes.        */
/*                                                                                                 */
/*    The most expensive operation is patient counting for each C_FULLNAME.  We determine the      */
/*    patient numbers associated with each code into the #CONCEPT_TO_PATIENTNUM table.  This     */
/*    table is far larger than its fact-count counterpart, potentially having millions of rows     */
/*    for a particular code if there are millions of patients with that type of fact.  By far,     */
/*    this extracts the most information from the fact table of any operation of this procedure.   */
/*    The table is then indexed on CONCEPT_CD.  The patient count for any C_FULLNAME is computed   */
/*    as the count of distinct patients from the set of patient numbers associated with all        */
/*    the codes for a C_FULLNAME.                                                                  */
/*                                                                                                 */
/*    NOTE:                                                                                        */
/*                                                                                                 */
/*    The procedure creates unique integer identifiers for unique C_FULLNAME and CONCEPT_CD        */
/*    values to reduce the size of values being compared are relatively small integer values       */
/*    instead of large character strings (e.g. 700 character C_FULLNAME strings).                  */
/*    These id values are only used in these temporary tables and not stored permanently.          */
/*    It is simply done to improve fact-counting performance.                                      */
/* ----------------------------------------------------------------------------------------------- */

BEGIN
    CREATE TABLE #FULLNAME_TO_ID (C_FULLNAME VARCHAR(750) NOT NULL UNIQUE, FULLNAME_ID BIGINT IDENTITY PRIMARY KEY); -- one id for each distinct C_FULLNAME
      -- NOTE: indexed on C_FULLNAME after loaded
    CREATE TABLE #CONCEPT_TO_ID (CONCEPT_CD VARCHAR(50) NOT NULL UNIQUE, CONCEPT_ID BIGINT IDENTITY PRIMARY KEY); -- one id for each distinct CONCEPT_CD
      -- NOTE: indexed on CONCEPT_CD after loaded
    CREATE TABLE #FULLNAME_TO_CONCEPT (FULLNAME_ID BIGINT PRIMARY KEY, CONCEPT_ID BIGINT NOT NULL); -- one id for each FULLNAME with non-NULL C_BASECODE
    CREATE INDEX CONCEPT_COVER_IDX on #FULLNAME_TO_CONCEPT(CONCEPT_ID) INCLUDE (FULLNAME_ID);
      -- NOTE: this was added in response to SSMS report of "Missing Index",
     --        during long-running #CONCEPT_TO_PATIENTDIM load for SNOMED CONDITIONS
    CREATE TABLE #ALL_FULLNAMES_TO_CONCEPTS (FULLNAME_ID BIGINT, CONCEPT_ID BIGINT NOT NULL); -- one to many
    SET @sql_string = N'ALTER TABLE #ALL_FULLNAMES_TO_CONCEPTS ADD CONSTRAINT UNIQ_AFTSC_' + replace(cast(newid() as Varchar(38)), '-', '_') + N'
                                        UNIQUE (FULLNAME_ID, CONCEPT_ID)';
    EXEC sp_executesql @sql_string;

      -- NOTE: one-time table load, using LIKE FULLNAME+% if no TRC table, ensuring that is only done once
      --       that is of importance because it can be a VERY slow operation for large metadata like SNOMED
      -- NOTE: indexed on FULLNAME_ID after load
    CREATE TABLE #FULLNAME_TO_SUBSUMED_CONCEPTS (FULLNAME_ID BIGINT, CONCEPT_ID BIGINT NOT NULL); -- one to many
    SET @sql_string = N'ALTER TABLE #ALL_FULLNAMES_TO_CONCEPTS ADD CONSTRAINT UNIQ_FTSC_' + replace(cast(newid() as Varchar(38)), '-', '_') + N'
                                        UNIQUE (FULLNAME_ID, CONCEPT_ID)';
    EXEC sp_executesql @sql_string;

    CREATE INDEX FULLNAME_COVER_IDX on #FULLNAME_TO_SUBSUMED_CONCEPTS(FULLNAME_ID) INCLUDE (CONCEPT_ID);
      -- NOTE: loaded specifically with FULLNAME_ID values from #TARGET_FULLNAME_IDS

    -- NOTE: CREATE INDEX statements allow DROP INDEX to be used after TRUNCATE statements
    --       allowing creating the index AFTER data is loaded for performance reasons.
    --       The tables can be loaded multiple times, so the DROP INDEX, CREATE INDEX sequence is done each time.

    CREATE TABLE #DISTINCT_CONCEPTS (CONCEPT_ID BIGINT NOT NULL PRIMARY KEY, CONCEPT_CD VARCHAR(50) NOT NULL UNIQUE);

    CREATE TABLE #CONCEPT_TO_FACTCOUNT (CONCEPT_ID INT NOT NULL UNIQUE, FACT_COUNT BIGINT NOT NULL); -- one value for each CONCEPT_CD
    CREATE INDEX CONCEPT_TO_FACTCOUNT_IDX ON #CONCEPT_TO_FACTCOUNT(CONCEPT_ID);

    CREATE TABLE #CONCEPT_TO_PATIENTNUM (CONCEPT_ID INT NOT NULL, PATIENT_NUM BIGINT NOT NULL); -- one to many, potentially very many
    CREATE INDEX CONCEPTID_COVER_IDX ON #CONCEPT_TO_PATIENTNUM(CONCEPT_ID) INCLUDE (PATIENT_NUM);
    -- NOTE: expensive, unnecessary constraint once used-- CONSTRAINT UNIQ_CONCEPT_TO_PATNUM UNIQUE (CONCEPT_ID, PATIENT_NUM)
    --  regardless,we count distinct PATIENT_NUM values across all codes from a FULLNAME.  Nearly doubled the time to execute.

    CREATE TABLE #FULLNAME_TO_FACTCOUNT (FULLNAME_ID INT NOT NULL UNIQUE, FACT_COUNT BIGINT NOT NULL); -- one value for each C_FULLNAME
    CREATE INDEX FULLNAME_TO_FACTCOUNT_IDX ON #FULLNAME_TO_FACTCOUNT(FULLNAME_ID);

    CREATE TABLE #FULLNAME_TO_PATIENTCOUNT (FULLNAME_ID INT NOT NULL UNIQUE, PATIENT_COUNT BIGINT NOT NULL); -- one value for each C_FULLNAME
    CREATE INDEX FULLNAME_TO_PATIENTCOUNT_IDX ON #FULLNAME_TO_PATIENTCOUNT(FULLNAME_ID);

    CREATE TABLE #FULLNAME_TO_COUNTS (C_FULLNAME VARCHAR(750) NOT NULL UNIQUE, FACT_COUNT BIGINT NOT NULL, PATIENT_COUNT BIGINT NOT NULL);
    CREATE INDEX FULLNAME_TO_COUNTS_IDX ON #FULLNAME_TO_COUNTS(C_FULLNAME);

    -- #TARGET_FULLNAMES, tracking batch of metadata rows, e.g. those targeted by M_APPLIED_PATH for a particular modifier metadata row
    CREATE TABLE #TARGET_FULLNAMES (C_FULLNAME VARCHAR(700) PRIMARY KEY);
    CREATE table #TARGET_FULLNAME_IDS (FULLNAME_ID BIGINT PRIMARY KEY);
    CREATE TABLE #PROCESSED_FULLNAMES (C_FULLNAME VARCHAR(700) PRIMARY KEY);
END

/* ----------------------------------------------------------------------------------------------------------- */
/*    Create mapping of FULLNAME to id for all non-modifier-metadata, one-time operation in procedure.         */
/*    NOTE: for non-TRC, this is the one place where the expensive LIKE operation on C_FULLNAME is used.       */
/* ----------------------------------------------------------------------------------------------------------- */

BEGIN
    SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_ID WITH (TABLOCK) (C_FULLNAME)
SELECT
 distinct C_FULLNAME
FROM
 ' + @metadata_table_name + N'
WHERE
 M_APPLIED_PATH=''@''';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_ID', N'(load:fullnames)', @row_count OUTPUT;
    SET @sql_string = N'CREATE INDEX FULLNAME_IDX ON #FULLNAME_TO_ID(C_FULLNAME)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_ID', N'(index:fullname)', @row_count OUTPUT;
END

/* ----------------------------------------------------------------------------------------------------------- */
/*    Create mapping of CONCEPT_CD to id for all non-modifier-metadata, one-time operation in procedure.         */
/*    NOTE: for non-TRC, this is the one place where the expensive LIKE operation on C_FULLNAME is used.       */
/* ----------------------------------------------------------------------------------------------------------- */

BEGIN
    SET @sql_string = N'
INSERT
INTO
 #CONCEPT_TO_ID WITH (TABLOCK) (CONCEPT_CD)
SELECT
 distinct C_BASECODE as CONCEPT_CD
FROM
 ' + @metadata_table_name + N'
WHERE
 M_APPLIED_PATH=''@''
 and C_BASECODE is not NULL';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_ID', N'(load:concepts)', @row_count OUTPUT;
    SET @sql_string = N'CREATE INDEX CONCEPT_IDX ON #CONCEPT_TO_ID(CONCEPT_CD)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_ID', N'(index:fullname)', @row_count OUTPUT;
END

/* ----------------------------------------------------------------------------------------------------------- */
/*    Create mapping of FULLNAME to CONCEPT for the single concept in the metadata row for that FULLNAME.      */
/*    No information for a FULLNAME with a C_BASECODE of NULL.                                                 */
/* ----------------------------------------------------------------------------------------------------------- */

BEGIN
    SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_CONCEPT WITH (TABLOCK) (FULLNAME_ID, CONCEPT_ID)
SELECT
 ftoi.FULLNAME_ID, ctoi.CONCEPT_ID
FROM
 ' + @metadata_table_name + N' m
 join #FULLNAME_TO_ID  ftoi on ftoi.C_FULLNAME = m.C_FULLNAME
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_CD = m.C_BASECODE
WHERE
 m.M_APPLIED_PATH=''@''
 and m.C_BASECODE is not NULL';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_CONCEPT', N'(load)', @row_count OUTPUT;
END

/* ----------------------------------------------------------------------------------------------------------- */
/*    SUBSUMPTION of concepts determination for each metadata row (#ALL_FULLNAMES_TO_CONCEPTS).                     */
/*                                                                                                             */
/*    Create one-to-many mapping of FULLNAME to CONCEPT_ID, listing all CONCEPT_ID values subsumed by the      */
/*    metadata row (based on TRC or LIKE C_FULLNAME processing).                                               */
/* ----------------------------------------------------------------------------------------------------------- */

BEGIN
    -- NOTE: currently we dont DROP INDEX and CREATE INDEX after data load for this table,
    --       we could add that if there is a performance issue identified later, so far it has been fine
    --       and it keeps the logic simple.
    IF @has_trc_table = 1 -- TRC table
    BEGIN
        SET @sql_string = N'
INSERT
INTO
 #ALL_FULLNAMES_TO_CONCEPTS WITH (TABLOCK) (FULLNAME_ID, CONCEPT_ID)
SELECT
 distinct ftoi.FULLNAME_ID, ctoi.CONCEPT_ID
FROM
 ' + @metadata_table_name + N' m
 join #FULLNAME_TO_ID  ftoi on ftoi.C_FULLNAME = m.C_FULLNAME
 join ' + @trc_table_name + N' trc on trc.SUPERTYPE_CNCPT = m.C_BASECODE
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_CD = trc.CONCEPT_CD
WHERE
 m.M_APPLIED_PATH=''@''
 and trc.CONCEPT_CD is not NULL';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#ALL_FULLNAMES_TO_CONCEPTS', N'(load)', @row_count OUTPUT;
    END
    ELSE
    BEGIN
        SET @sql_string = N'
INSERT
INTO
 #ALL_FULLNAMES_TO_CONCEPTS WITH (TABLOCK) (FULLNAME_ID, CONCEPT_ID)
SELECT
 distinct ftoi.FULLNAME_ID, ctoi.CONCEPT_ID
FROM
 ' + @metadata_table_name + N' m
 join #FULLNAME_TO_ID  ftoi on ftoi.C_FULLNAME = m.C_FULLNAME
 join #FULLNAME_TO_ID  ftoi2 on ftoi2.C_FULLNAME like m.C_FULLNAME+''%''
 join #FULLNAME_TO_CONCEPT ftoc on ftoc.FULLNAME_ID = ftoi2.FULLNAME_ID
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_ID = ftoc.CONCEPT_ID
WHERE
 m.M_APPLIED_PATH=''@''';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#ALL_FULLNAMES_TO_CONCEPTS', N'(load)', @row_count OUTPUT;
    END
    SET @sql_string = N'CREATE INDEX FULLNAME_TO_CONCEPTS_IDX ON #ALL_FULLNAMES_TO_CONCEPTS(FULLNAME_ID)';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#ALL_FULLNAMES_TO_CONCEPTS', N'(index:fullnameid-to-conceptid)', @row_count OUTPUT;
END

/* ----------------------------------------------------------------- */
/*    Fact count any metadata rows targeted by modifier metadata.    */
/* ----------------------------------------------------------------- */

BEGIN
    SET @proc_row_count = 0;
    SET @sql_string = N'SELECT DISTINCT M_APPLIED_PATH FROM ' + @metadata_table_name + N' WHERE M_APPLIED_PATH<>''@'' ORDER BY M_APPLIED_PATH';
    SET @s = N'DECLARE m_applied_path_cursor CURSOR FORWARD_ONLY READ_ONLY FOR ' + @sql_string;
    EXEC sp_executesql @sql = @s;
    OPEN m_applied_path_cursor;
    FETCH NEXT FROM m_applied_path_cursor INTO @m_applied_path;
    WHILE @@FETCH_STATUS = 0
    BEGIN -- e.g. m_applied_path = '\i2b2_SNOMEDCT_CONDITIONS\%'

        -----------------------------------------------------------------------------------------------
        -- Update #TARGET_FULLNAMES with C_FULLNAME values associated with the current M_APPLIED_PATH
        -----------------------------------------------------------------------------------------------

        TRUNCATE TABLE #TARGET_FULLNAMES;
        SET @sql_string = N'
INSERT INTO #TARGET_FULLNAMES WITH (TABLOCK) (C_FULLNAME)
SELECT DISTINCT C_FULLNAME FROM ' + @metadata_table_name + N' WHERE M_APPLIED_PATH=''@'' and C_FULLNAME LIKE ''' + @m_applied_path + N'''';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#TARGET_FULLNAMES', N'(modifier-path)', @row_count OUTPUT;

        if @row_count > 0 -- there exist rows that were not targeted by modifier metdata ==> FACT COUNT THEM
        BEGIN
            SET @log_msg = 'target_paths:' + @m_applied_path + ':' + cast(@row_count as VARCHAR(18));
            EXEC LOG_MESSAGE @log_msg, @proc_name, N'#TARGET_FULLNAMES'

            -- TRACK C_FULLNAME values that have been processed
            INSERT INTO #PROCESSED_FULLNAMES WITH (TABLOCK) (C_FULLNAME)
            SELECT a.C_FULLNAME FROM #TARGET_FULLNAMES a left join #PROCESSED_FULLNAMES b on b.C_FULLNAME = a.C_FULLNAME WHERE b.C_FULLNAME is NULL;

            ----------------------------------------------------------------------------------------------------
            -- #TARGET_FULLNAME_IDS, temp temp with only the FULLNAME_ID values for #TARGET_FULLNAMES
            --   simplifies many join operations, would otherwise join #TARGET_FULLNAMES and #FULLNAME_TO_ID
            ----------------------------------------------------------------------------------------------------

            TRUNCATE TABLE #TARGET_FULLNAME_IDS;
            SET @sql_string = N'
INSERT into #TARGET_FULLNAME_IDS WITH (TABLOCK) (FULLNAME_ID)
SELECT ftoi.FULLNAME_ID from #TARGET_FULLNAMES t join #FULLNAME_TO_ID ftoi on ftoi.C_FULLNAME=t.C_FULLNAME';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#TARGET_FULLNAME_IDS', N'(load)', @row_count OUTPUT;

            ----------------------------------------------------------------------------------------------------------------
            --  #CONCEPT_TO_FACTCOUNT temp table with code to fact_count mapping (additive, set not needed).
            --   Cant be done outside of the cursor loop -- set of modifier codes can differ each time (impacts result).
            --  NODE: requires two steps, first step to find distinct CONCEPT_ID values, second step to fact-count.
            ----------------------------------------------------------------------------------------------------------------

            TRUNCATE TABLE #DISTINCT_CONCEPTS; -- PRIMARY KEY of CONCEPT_ID, no additional index
            SET @sql_string = N'
INSERT
INTO #DISTINCT_CONCEPTS WITH (TABLOCK) (CONCEPT_ID, CONCEPT_CD)
SELECT
 DISTINCT ctoi.CONCEPT_ID, ctoi.CONCEPT_CD
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_CONCEPT ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_ID = ftoc.CONCEPT_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#DISTINCT_CONCEPTS', N'(load)', @row_count OUTPUT;

            TRUNCATE TABLE #CONCEPT_TO_FACTCOUNT;
            DROP INDEX CONCEPT_TO_FACTCOUNT_IDX ON #CONCEPT_TO_FACTCOUNT; -- dont want it to be indexed yet, performance issue
 
            SET @sql_string = N'
INSERT
INTO
 #CONCEPT_TO_FACTCOUNT WITH (TABLOCK) (CONCEPT_ID, FACT_COUNT)
SELECT
 dc.CONCEPT_ID as CONCEPT_ID, count(f.CONCEPT_CD) as FACT_COUNT
FROM
 #DISTINCT_CONCEPTS dc
 join BlueheronData.dbo.OBSERVATION_FACT f
     on f.CONCEPT_CD = dc.CONCEPT_CD
        and f.MODIFIER_CD in (SELECT C_BASECODE as MODIFIER_CD from ' + @metadata_table_name + N' m
                              WHERE M_APPLIED_PATH=''' + @m_applied_path + N''')
GROUP BY
 dc.CONCEPT_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_FACTCOUNT', N'(load)', @row_count OUTPUT;
            -- index on CONCEPT_ID
            SET @sql_string = N'CREATE INDEX CONCEPT_TO_FACTCOUNT_IDX ON #CONCEPT_TO_FACTCOUNT(CONCEPT_ID)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_FACTCOUNT', N'(index:CONCEPT_ID)', @row_count OUTPUT;

            ---------------------------------------------------------------------------------------------------------------
            -- #CONCEPT_TO_PATIENTNUM temp table with code to distinct patient_num rows (not additive, set needed).
            --   Cant be done outside of the cursor loop -- set of modifier codes can differ each time (impacts result).
            --   NOTE: no GROUP BY, must track each PATIENT_NUM individually
            ---------------------------------------------------------------------------------------------------------------

            TRUNCATE TABLE #CONCEPT_TO_PATIENTNUM;
            DROP INDEX CONCEPTID_COVER_IDX ON #CONCEPT_TO_PATIENTNUM; -- dont want index yet, performance issue

            SET @sql_string = N'
INSERT
INTO
 #CONCEPT_TO_PATIENTNUM WITH (TABLOCK) (CONCEPT_ID, PATIENT_NUM)
SELECT
 distinct ctoi.CONCEPT_ID, f.PATIENT_NUM
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_CONCEPT ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_ID = ftoc.CONCEPT_ID
 join BlueheronData.dbo.OBSERVATION_FACT f
     on f.CONCEPT_CD = ctoi.CONCEPT_CD
        and f.MODIFIER_CD in (SELECT C_BASECODE as MODIFIER_CD from ' + @metadata_table_name + N' m
                              WHERE M_APPLIED_PATH=''' + @m_applied_path + N''')';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_PATIENTNUM', N'(load)', @row_count OUTPUT;
            -- index on CONCEPT_ID, COVER with PATIENT_NUM
            SET @sql_string = N'CREATE INDEX CONCEPTID_COVER_IDX ON #CONCEPT_TO_PATIENTNUM(CONCEPT_ID) INCLUDE (PATIENT_NUM)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_PATIENTNUM', N'(index:CONCEPTID_COVER)', @row_count OUTPUT;

            ----------------------------------------------------------------
            -- #FULLNAME_TO_SUBSUMED_CONCEPTS, prep for fact and patient-counting
            ----------------------------------------------------------------
            TRUNCATE TABLE #FULLNAME_TO_SUBSUMED_CONCEPTS;
            DROP INDEX FULLNAME_COVER_IDX on #FULLNAME_TO_SUBSUMED_CONCEPTS;

            SET @sql_string = N'
INSERT into #FULLNAME_TO_SUBSUMED_CONCEPTS WITH (TABLOCK) (FULLNAME_ID, CONCEPT_ID)
select tf.FULLNAME_ID, ftoc.CONCEPT_ID
from
 #TARGET_FULLNAME_IDS tf
 join #ALL_FULLNAMES_TO_CONCEPTS ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_SUBSUMED_CONCEPTS', N'(load)', @row_count OUTPUT
            -- index
            SET @sql_string = N'CREATE INDEX FULLNAME_COVER_IDX on #FULLNAME_TO_SUBSUMED_CONCEPTS(FULLNAME_ID) INCLUDE (CONCEPT_ID)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_SUBSUMED_CONCEPTS', N'(index:FULLNAME_CONCEPT)', @row_count OUTPUT;

            -------------------------------------------------------------------
            -- #FULLNAME_TO_FACTCOUNT table with path to fact count mapping.
            -------------------------------------------------------------------

            TRUNCATE TABLE #FULLNAME_TO_FACTCOUNT;
            DROP INDEX FULLNAME_TO_FACTCOUNT_IDX ON #FULLNAME_TO_FACTCOUNT;

            SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_FACTCOUNT WITH (TABLOCK) (FULLNAME_ID, FACT_COUNT)
SELECT
 ftoc.FULLNAME_ID, SUM(c.FACT_COUNT) as FACT_COUNT
FROM
 #FULLNAME_TO_SUBSUMED_CONCEPTS ftoc
 join #CONCEPT_TO_FACTCOUNT c on c.CONCEPT_ID = ftoc.CONCEPT_ID
GROUP BY
 ftoc.FULLNAME_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_FACTCOUNT', N'(load)', @row_count OUTPUT
            -- index on FULLNAME_ID
            SET @sql_string = N'CREATE INDEX FULLNAME_TO_FACTCOUNT_IDX ON #FULLNAME_TO_FACTCOUNT(FULLNAME_ID)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_FACTCOUNT', N'(index:FULLNAME_ID)', @row_count OUTPUT;

            -------------------------------------------------------------------------
            -- #FULLNAME_TO_PATIENTCOUNT table with path to patient count mapping.
            -------------------------------------------------------------------------

            TRUNCATE TABLE #FULLNAME_TO_PATIENTCOUNT;
            DROP INDEX FULLNAME_TO_PATIENTCOUNT_IDX ON #FULLNAME_TO_PATIENTCOUNT;

            SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_PATIENTCOUNT WITH (TABLOCK) (FULLNAME_ID, PATIENT_COUNT)
SELECT
 ftoc.FULLNAME_ID, COUNT(distinct c.PATIENT_NUM) as PATIENT_COUNT
FROM
 #FULLNAME_TO_SUBSUMED_CONCEPTS ftoc
 join #CONCEPT_TO_PATIENTNUM c on c.CONCEPT_ID = ftoc.CONCEPT_ID
GROUP BY
 ftoc.FULLNAME_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_PATIENTCOUNT', N'(load)', @row_count OUTPUT;
            -- index on FULLNAME_ID
            SET @sql_string = N'CREATE INDEX FULLNAME_TO_PATIENTCOUNT_IDX ON #FULLNAME_TO_PATIENTCOUNT(FULLNAME_ID)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_PATIENTCOUNT', N'(index:FULLNAME_ID)', @row_count OUTPUT

            -----------------------------------------------------------------------------------
            --  #FULLNAME_TO_COUNTS table with path to fact count AND patient count mapping.
            -----------------------------------------------------------------------------------

            TRUNCATE TABLE #FULLNAME_TO_COUNTS;
            DROP INDEX FULLNAME_TO_COUNTS_IDX ON #FULLNAME_TO_COUNTS; -- dont want index yet, performance

            SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_COUNTS WITH (TABLOCK) (C_FULLNAME, FACT_COUNT, PATIENT_COUNT)
SELECT
 ftoi.C_FULLNAME, factcount.FACT_COUNT, patientcount.PATIENT_COUNT
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_ID ftoi on ftoi.FULLNAME_ID = tf.FULLNAME_ID
 join #FULLNAME_TO_PATIENTCOUNT patientcount on patientcount.FULLNAME_ID = tf.FULLNAME_ID
 join #FULLNAME_TO_FACTCOUNT factcount on factcount.FULLNAME_ID = tf.FULLNAME_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_COUNTS', N'(load)', @row_count OUTPUT
            -- index on FULLNAME_ID
            SET @sql_string = N'CREATE INDEX FULLNAME_TO_COUNTS_IDX ON #FULLNAME_TO_COUNTS(C_FULLNAME)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_COUNTS', N'(index:C_FULLNAME)', @row_count OUTPUT;

            ---------------------------------------------------------------------------------------------------
            -- FINALLY, UPDATE THE METADATA TABLE PATIENT_COUNT and FACT_COUNT using #FULLNAME_TO_COUNTS
            -- NOTE: no need to join with #TARGET_FULLNAMES here, was used in FULLNAME_TO_COUNTS processing
            ---------------------------------------------------------------------------------------------------

            SET @sql_string = N'
MERGE
INTO
 ' + @metadata_table_name + N' m
USING
 #FULLNAME_TO_COUNTS f
ON
 (m.C_FULLNAME = f.C_FULLNAME)
WHEN matched then
 UPDATE
 SET
  m.FACT_COUNT = f.FACT_COUNT,
  m.C_TOTALNUM = f.PATIENT_COUNT;'
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(compute-counts)', @row_count OUTPUT;

            ------------------------------------------
            -- End of if @row_count > 0 processing
            ------------------------------------------

            SET @proc_row_count = @proc_row_count + @row_count;
        END  -- ends IF @row_count > 0

        FETCH NEXT FROM m_applied_path_cursor INTO @m_applied_path;
    END -- ends WHILE @@FETCH_STATUS = 0

    -----------------------------------------------------------------------------
    -- Aftermath of WHILE loop on cursor, clean up cursor (release resources)
    -----------------------------------------------------------------------------

    CLOSE m_applied_path_cursor;
    DEALLOCATE m_applied_path_cursor;
END

/* --------------------------------------------------------------------------------- */
/*    Fact count metadata rows NOT targeted by modifier metadata (may not exist).    */
/* --------------------------------------------------------------------------------- */

BEGIN
    ------------------------------------------------------------------------------------------------------------------------
    -- #TARGET_FULLNAMES -- remaining C_FULLNAME values from metadata table that are NOT targeted by modifier metadata,
    --                      there may not be any or it could be ALL of the non-modifier rows.
    ------------------------------------------------------------------------------------------------------------------------

    TRUNCATE TABLE #TARGET_FULLNAMES;
    SET @sql_string = N'
INSERT INTO #TARGET_FULLNAMES WITH (TABLOCK) (C_FULLNAME)
SELECT DISTINCT m.C_FULLNAME
FROM ' + @metadata_table_name + N' m
 left join #PROCESSED_FULLNAMES t on m.C_FULLNAME=t.C_FULLNAME
WHERE
 m.M_APPLIED_PATH=''@'' AND t.C_FULLNAME IS NULL';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#TARGET_FULLNAMES', N'(nomodifier-paths)', @row_count OUTPUT;

    IF @row_count > 0 -- there exist rows that were not targeted by modifier metdata ==> FACT COUNT THEM
    BEGIN
        SET @log_msg = 'target_paths:no-modifiers:' + cast(@row_count as VARCHAR(18));
        EXEC LOG_MESSAGE @log_msg, @proc_name, N'#TARGET_FULLNAMES';

        ----------------------------------------------------------------------------------------------------
        -- #TARGET_FULLNAME_IDS, temp temp with only the FULLNAME_ID values for #TARGET_FULLNAMES
        --   simplifies many join operations, would otherwise join #TARGET_FULLNAMES and #FULLNAME_TO_ID
        ----------------------------------------------------------------------------------------------------

        TRUNCATE TABLE #TARGET_FULLNAME_IDS;
        SET @sql_string = N'
INSERT into #TARGET_FULLNAME_IDS WITH (TABLOCK) (FULLNAME_ID)
SELECT ftoi.FULLNAME_ID from #TARGET_FULLNAMES t join #FULLNAME_TO_ID ftoi on ftoi.C_FULLNAME=t.C_FULLNAME';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#TARGET_FULLNAME_IDS', N'(load)', @row_count OUTPUT;

        ----------------------------------------------------------------------------------------------------------------
        --  #CONCEPT_TO_FACTCOUNT temp table with code to fact_count mapping (additive, set not needed).
        --   Cant be done outside of the cursor loop -- set of modifier codes can differ each time (impacts result).
        ----------------------------------------------------------------------------------------------------------------

            TRUNCATE TABLE #DISTINCT_CONCEPTS; -- PRIMARY KEY of CONCEPT_ID, no additional index
            SET @sql_string = N'
INSERT
INTO #DISTINCT_CONCEPTS WITH (TABLOCK) (CONCEPT_ID, CONCEPT_CD)
SELECT
 DISTINCT ctoi.CONCEPT_ID, ctoi.CONCEPT_CD
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_CONCEPT ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_ID = ftoc.CONCEPT_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#DISTINCT_CONCEPTS', N'(load)', @row_count OUTPUT;

            TRUNCATE TABLE #CONCEPT_TO_FACTCOUNT;
            DROP INDEX CONCEPT_TO_FACTCOUNT_IDX ON #CONCEPT_TO_FACTCOUNT; -- dont want it to be indexed yet, performance issue
 
            SET @sql_string = N'
INSERT
INTO
 #CONCEPT_TO_FACTCOUNT WITH (TABLOCK) (CONCEPT_ID, FACT_COUNT)
SELECT
 dc.CONCEPT_ID as CONCEPT_ID, count(f.CONCEPT_CD) as FACT_COUNT
FROM
 #DISTINCT_CONCEPTS dc
 join BlueheronData.dbo.OBSERVATION_FACT f
     on f.CONCEPT_CD = dc.CONCEPT_CD
GROUP BY
 dc.CONCEPT_ID';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_FACTCOUNT', N'(load)', @row_count OUTPUT;
        -- index on CONCEPT_ID
        SET @sql_string = N'CREATE INDEX CONCEPT_TO_FACTCOUNT_IDX ON #CONCEPT_TO_FACTCOUNT(CONCEPT_ID)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_FACTCOUNT', N'(index:CONCEPT_ID)', @row_count OUTPUT

        ---------------------------------------------------------------------------------------------------------------
        -- #CONCEPT_TO_PATIENTNUM temp table with code to distinct patient_num rows (not additive, set needed).
        --   Cant be done outside of the cursor loop -- set of modifier codes can differ each time (impacts result).
        --   NOTE: no GROUP BY, must track each PATIENT_NUM individually
        ---------------------------------------------------------------------------------------------------------------

        TRUNCATE TABLE #CONCEPT_TO_PATIENTNUM;
        DROP INDEX CONCEPTID_COVER_IDX ON #CONCEPT_TO_PATIENTNUM; -- dont want index yet, performance issue

        SET @sql_string = N'
INSERT
INTO
 #CONCEPT_TO_PATIENTNUM WITH (TABLOCK) (CONCEPT_ID, PATIENT_NUM)
SELECT
 distinct ctoi.CONCEPT_ID, f.PATIENT_NUM
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_CONCEPT ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID
 join #CONCEPT_TO_ID ctoi on ctoi.CONCEPT_ID = ftoc.CONCEPT_ID
 join BlueheronData.dbo.OBSERVATION_FACT f
     on f.CONCEPT_CD = ctoi.CONCEPT_CD';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_PATIENTNUM', N'(load)', @row_count OUTPUT;
        -- index on CONCEPT_ID, COVER with PATIENT_NUM
        SET @sql_string = N'CREATE INDEX CONCEPTID_COVER_IDX ON #CONCEPT_TO_PATIENTNUM(CONCEPT_ID) INCLUDE (PATIENT_NUM)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#CONCEPT_TO_PATIENTNUM', N'(index:CONCEPTID_COVER)', @row_count OUTPUT;

            ----------------------------------------------------------------
            -- #FULLNAME_TO_SUBSUMED_CONCEPTS, prep for fact and patient-counting
            ----------------------------------------------------------------
            TRUNCATE TABLE #FULLNAME_TO_SUBSUMED_CONCEPTS;
            DROP INDEX FULLNAME_COVER_IDX on #FULLNAME_TO_SUBSUMED_CONCEPTS;

            SET @sql_string = N'
INSERT into #FULLNAME_TO_SUBSUMED_CONCEPTS WITH (TABLOCK) (FULLNAME_ID, CONCEPT_ID)
select tf.FULLNAME_ID, ftoc.CONCEPT_ID
from
 #TARGET_FULLNAME_IDS tf
 join #ALL_FULLNAMES_TO_CONCEPTS ftoc on ftoc.FULLNAME_ID = tf.FULLNAME_ID';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_SUBSUMED_CONCEPTS', N'(load)', @row_count OUTPUT
            -- index
            SET @sql_string = N'CREATE INDEX FULLNAME_COVER_IDX on #FULLNAME_TO_SUBSUMED_CONCEPTS(FULLNAME_ID) INCLUDE (CONCEPT_ID)';
            EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_SUBSUMED_CONCEPTS', N'(index:FULLNAME_CONCEPT)', @row_count OUTPUT;

        -------------------------------------------------------------------
        -- #FULLNAME_TO_FACTCOUNT table with path to fact count mapping.
        -------------------------------------------------------------------

        TRUNCATE TABLE #FULLNAME_TO_FACTCOUNT;
        DROP INDEX FULLNAME_TO_FACTCOUNT_IDX ON #FULLNAME_TO_FACTCOUNT;

        SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_FACTCOUNT WITH (TABLOCK) (FULLNAME_ID, FACT_COUNT)
SELECT
 ftoc.FULLNAME_ID, SUM(c.FACT_COUNT) as FACT_COUNT
FROM
 #FULLNAME_TO_SUBSUMED_CONCEPTS ftoc
 join #CONCEPT_TO_FACTCOUNT c on c.CONCEPT_ID = ftoc.CONCEPT_ID
GROUP BY
 ftoc.FULLNAME_ID';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_FACTCOUNT', N'(load)', @row_count OUTPUT
        -- index on FULLNAME_ID
        SET @sql_string = N'CREATE INDEX FULLNAME_TO_FACTCOUNT_IDX ON #FULLNAME_TO_FACTCOUNT(FULLNAME_ID)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_FACTCOUNT', N'(index:FULLNAME_ID)', @row_count OUTPUT;

        -------------------------------------------------------------------------
        -- #FULLNAME_TO_PATIENTCOUNT table with path to patient count mapping.
        -------------------------------------------------------------------------

        TRUNCATE TABLE #FULLNAME_TO_PATIENTCOUNT;
        DROP INDEX FULLNAME_TO_PATIENTCOUNT_IDX ON #FULLNAME_TO_PATIENTCOUNT;

        SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_PATIENTCOUNT WITH (TABLOCK) (FULLNAME_ID, PATIENT_COUNT)
SELECT
 ftoc.FULLNAME_ID, COUNT(distinct c.PATIENT_NUM) as PATIENT_COUNT
FROM
 #FULLNAME_TO_SUBSUMED_CONCEPTS ftoc
 join #CONCEPT_TO_PATIENTNUM c on c.CONCEPT_ID = ftoc.CONCEPT_ID
GROUP BY
 ftoc.FULLNAME_ID';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_PATIENTCOUNT', N'(load)', @row_count OUTPUT;
        -- index on FULLNAME_ID
        SET @sql_string = N'CREATE INDEX FULLNAME_TO_PATIENTCOUNT_IDX ON #FULLNAME_TO_PATIENTCOUNT(FULLNAME_ID)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_PATIENTCOUNT', N'(index:FULLNAME_ID)', @row_count OUTPUT

        -----------------------------------------------------------------------------------
        --  #FULLNAME_TO_COUNTS table with path to fact count AND patient count mapping.
        -----------------------------------------------------------------------------------

        TRUNCATE TABLE #FULLNAME_TO_COUNTS;
        DROP INDEX FULLNAME_TO_COUNTS_IDX ON #FULLNAME_TO_COUNTS; -- dont want index yet, performance

        SET @sql_string = N'
INSERT
INTO
 #FULLNAME_TO_COUNTS WITH (TABLOCK) (C_FULLNAME, FACT_COUNT, PATIENT_COUNT)
SELECT
 ftoi.C_FULLNAME, factcount.FACT_COUNT, patientcount.PATIENT_COUNT
FROM
 #TARGET_FULLNAME_IDS tf
 join #FULLNAME_TO_ID ftoi on ftoi.FULLNAME_ID = tf.FULLNAME_ID
 join #FULLNAME_TO_PATIENTCOUNT patientcount on patientcount.FULLNAME_ID = tf.FULLNAME_ID
 join #FULLNAME_TO_FACTCOUNT factcount on factcount.FULLNAME_ID = tf.FULLNAME_ID';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_COUNTS', N'(load)', @row_count OUTPUT
        -- index on FULLNAME_ID
        SET @sql_string = N'CREATE INDEX FULLNAME_TO_COUNTS_IDX ON #FULLNAME_TO_COUNTS(C_FULLNAME)';
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'#FULLNAME_TO_COUNTS', N'(index:C_FULLNAME)', @row_count OUTPUT;

        ---------------------------------------------------------------------------------------------------
        -- FINALLY, UPDATE THE METADATA TABLE PATIENT_COUNT and FACT_COUNT using #FULLNAME_TO_COUNTS
        -- NOTE: no need to join with #TARGET_FULLNAMES here, was used in FULLNAME_TO_COUNTS processing
        ---------------------------------------------------------------------------------------------------

        SET @sql_string = N'
MERGE
INTO
 ' + @metadata_table_name + N' m
USING
 #FULLNAME_TO_COUNTS f
ON
 (m.C_FULLNAME = f.C_FULLNAME)
WHEN matched then
 UPDATE
 SET
  m.FACT_COUNT = f.FACT_COUNT,
  m.C_TOTALNUM = f.PATIENT_COUNT;'
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(compute-counts)', @row_count OUTPUT;

        ------------------------------------------
        -- End of if @row_count > 0 processing
        ------------------------------------------

        SET @proc_row_count = @proc_row_count + @row_count;
    END
END


/* ----------------------------------------------------------------------------------- */
/*    Remove previous fact-count from C_NAME string (i.e. ([ X facts; Y patients]).    */
/* ----------------------------------------------------------------------------------- */

BEGIN
    SET @sql_string = N'
UPDATE ' + @metadata_table_name + N'
SET
 C_NAME = substring(C_NAME, 1, (dbo.INSTR(C_NAME, ''['', -1, 1) -1))
WHERE
 M_APPLIED_PATH=''@'' and dbo.INSTR(C_NAME, ''['', -1, 1) > 1';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(cleanup-cname)', @row_count OUTPUT;
END

/* ---------------------------------------------------------------------- */
/*    Set fact-count information in C_NAME string where FACT_COUNT > 0    */
/* ---------------------------------------------------------------------- */

BEGIN
    SET @sql_string = N'
UPDATE
 ' + @metadata_table_name + N'
SET
 C_NAME = C_NAME + '' '' + dbo.FACT_COUNT_STRING(cast(FACT_COUNT as BIGINT), cast(C_TOTALNUM as BIGINT))
WHERE
 FACT_COUNT > 0 and M_APPLIED_PATH=''@''';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(set-fact-count)', @row_count OUTPUT;
END

/* --------------------------------------------------- */
/*    Hide folders, leaves with fact-count of zero.    */
/* --------------------------------------------------- */

BEGIN
    SET @sql_string = N'
UPDATE
 ' + @metadata_table_name + N'
SET
 C_VISUALATTRIBUTES = substring(C_VISUALATTRIBUTES, 1, 1) + (case when FACT_COUNT = 0 then ''H'' else ''A'' end) + substring(C_VISUALATTRIBUTES, 3, 1)
WHERE
 M_APPLIED_PATH=''@''';
    EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, @metadata_table_name, N'(hide-zero-counts)', @row_count OUTPUT;
END

/* -------------------------------------------------- */
/*    Update count in TABLE_ACCESS, if requested.    */
/* -------------------------------------------------- */

IF @update_table_access = 1
BEGIN
    -- Iterate through TABLE_ACCESS looking for all rows where C_TABLE_NAME is the target table (C_TABLE_NAME=@md_table_name).
    -- Each has a C_FULLNAME row specification from which to extract FACT_COUNT and C_TOTALNUM, allowing
    -- C_NAME to be updated for that row, using its unique C_TABLE_CD.

    SET @sql_string = N'SELECT DISTINCT C_TABLE_CD, C_FULLNAME FROM ' + @metadata_db_prefix + N'dbo.TABLE_ACCESS WHERE C_TABLE_NAME=''' + @md_table_name + N''' ORDER BY C_TABLE_CD';
    SET @s = N'DECLARE table_access_cursor CURSOR FORWARD_ONLY READ_ONLY FOR ' + @sql_string;
    EXEC sp_executesql @sql = @s;
    OPEN table_access_cursor;
    FETCH NEXT FROM table_access_cursor INTO @table_cd, @fullname; -- e.g. c_table_cd = 'unmc_demo', fullname = '\i2b2\Demographics\'
    WHILE @@FETCH_STATUS = 0
    BEGIN -- e.g. c_table_cd = 'unmc_demographics', fullname = '\i2b2\Demographics\'
        -- Extract fact count and patient count for the specified metadata table.
        SET @sql_string = N'SELECT @fact_count = cast(FACT_COUNT AS BIGINT) FROM ' + @metadata_table_name + N' WHERE C_FULLNAME = ''' + @fullname + N'''';
        EXEC sp_executesql @sql_string, N'@fact_count BIGINT OUTPUT', @fact_count = @fact_count OUTPUT;
        SET @sql_string = N'SELECT @patient_count = cast(C_TOTALNUM AS BIGINT) FROM ' + @metadata_table_name + N' WHERE C_FULLNAME = ''' + @fullname + N'''';
        EXEC sp_executesql @sql_string, N'@patient_count BIGINT OUTPUT', @patient_count = @patient_count OUTPUT;
        -- Determine the C_NAME for TABLE_ACCESS for this metadata table, update based on fact+patient counts.
        SET @sql_string = N'SELECT @c_name = case when dbo.INSTR(C_NAME, ''['', -1, 1) > 1 then substring(C_NAME, 1, (dbo.INSTR(C_NAME, ''['', -1, 1) - 1)) else C_NAME end FROM ' + @metadata_db_prefix + N'dbo.TABLE_ACCESS WHERE C_TABLE_CD = ''' + @table_cd + N''''
        EXEC sp_executesql @Query = @sql_string, @Params = N'@c_name VARCHAR(2000) OUTPUT', @c_name = @c_name OUTPUT
        SET @c_name = @c_name + ' ' + dbo.FACT_COUNT_STRING(@fact_count, @patient_count)
        -- Update TABLE_ACCESS
        SET @sql_string = N'
UPDATE
 ' + @metadata_db_prefix + N'dbo.TABLE_ACCESS
SET
 C_NAME = ''' + @c_name + N'''' + N'
WHERE
 C_TABLE_CD = ''' + @table_cd + N''''
        EXEC RUN_SQL_WITH_LOGGING @sql_string, @proc_name, N'TABLE_ACCESS', N'(set-C_NAME)', @row_count OUTPUT;
        FETCH NEXT FROM table_access_cursor INTO @table_cd, @fullname;
    END

    /* Close and deallocate the cursor (release resources) */
    CLOSE table_access_cursor;
    DEALLOCATE table_access_cursor;
END

/* --------------- */
/*    Terminate    */
/* --------------- */

BEGIN
    EXEC LOG_TABLE_BUILD_END @proc_build_id, @proc_row_count;
END

RETURN 0;

END