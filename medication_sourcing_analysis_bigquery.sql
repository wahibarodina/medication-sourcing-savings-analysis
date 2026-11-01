-- Medication Sourcing Savings Analysis - BigQuery Standard SQL
-- Project: medication-sourcing-portfolio | Dataset: med_sourcing (US)
-- Limits: CMS is gross Part D claim cost, not acquisition cost. The manufacturer
-- spread is a proxy, not manufacturer-specific NADAC pricing. The 100% reference
-- gap is mechanical, not realized savings.

-- One-time normalization after the CSV loader preserved NADAC header spaces.
-- Rename the uploaded table from nadac_2026 to nadac_2026_raw before this step.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.nadac_2026` AS
SELECT
  `NDC Description` AS NDC_Description,
  LPAD(CAST(NDC AS STRING), 11, '0') AS NDC,
  SAFE_CAST(`NADAC Per Unit` AS FLOAT64) AS NADAC_Per_Unit,
  CAST(`Effective Date` AS STRING) AS Effective_Date,
  CAST(`Pricing Unit` AS STRING) AS Pricing_Unit,
  CAST(`Pharmacy Type Indicator` AS STRING) AS Pharmacy_Type_Indicator,
  CAST(OTC AS STRING) AS OTC,
  CAST(`Explanation Code` AS STRING) AS Explanation_Code,
  CAST(`Classification for Rate Setting` AS STRING) AS Classification_for_Rate_Setting,
  SAFE_CAST(`Corresponding Generic Drug NADAC Per Unit` AS FLOAT64) AS Corresponding_Generic_Drug_NADAC_Per_Unit,
  CAST(`Corresponding Generic Drug Effective Date` AS STRING) AS Corresponding_Generic_Drug_Effective_Date,
  CAST(`As of Date` AS STRING) AS As_of_Date
FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026_raw`;

-- Query 1 of 10: Profile CMS grain and row roles.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q01_cms_profile` AS
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT CONCAT(UPPER(TRIM(Brnd_Name)), '|', UPPER(TRIM(Gnrc_Name)))) AS drug_keys,
  COUNTIF(Mftr_Name = 'Overall') AS overall_rows,
  COUNTIF(Mftr_Name != 'Overall') AS manufacturer_detail_rows,
  MIN(Tot_Spndng_2024) AS min_2024_spend,
  MAX(Tot_Spndng_2024) AS max_2024_spend
FROM `medication-sourcing-portfolio.med_sourcing.cms_part_d_2024`;

-- Query 2 of 10: Reconcile manufacturer detail to each Overall control row.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q02_manufacturer_reconciliation` AS
WITH tagged AS (
  SELECT
    CONCAT(UPPER(TRIM(Brnd_Name)), '|', UPPER(TRIM(Gnrc_Name))) AS drug_key,
    Mftr_Name, Tot_Spndng_2024 AS spend, Tot_Dsg_Unts_2024 AS units
  FROM `medication-sourcing-portfolio.med_sourcing.cms_part_d_2024`
), reconciled AS (
  SELECT
    drug_key,
    MAX(IF(Mftr_Name = 'Overall', spend, NULL)) AS overall_spend,
    SUM(IF(Mftr_Name != 'Overall', spend, 0)) AS detail_spend,
    MAX(IF(Mftr_Name = 'Overall', units, NULL)) AS overall_units,
    SUM(IF(Mftr_Name != 'Overall', units, 0)) AS detail_units
  FROM tagged GROUP BY drug_key
)
SELECT
  *,
  SAFE_DIVIDE(detail_spend, overall_spend) - 1 AS spend_reconciliation_pct,
  SAFE_DIVIDE(detail_units, overall_units) - 1 AS unit_reconciliation_pct
FROM reconciled WHERE overall_spend IS NOT NULL;

-- Query 3 of 10: Confirm the latest NADAC snapshot and NDC uniqueness.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q03_nadac_snapshot` AS
WITH parsed AS (
  SELECT *, SAFE.PARSE_DATE('%m/%d/%Y', As_of_Date) AS as_of_date_parsed
  FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026`
), latest AS (SELECT MAX(as_of_date_parsed) AS max_as_of_date FROM parsed)
SELECT
  max_as_of_date,
  COUNT(*) AS current_rows,
  COUNT(DISTINCT NDC) AS current_unique_ndcs,
  COUNT(*) - COUNT(DISTINCT NDC) AS duplicate_ndc_rows
FROM parsed CROSS JOIN latest
WHERE as_of_date_parsed = max_as_of_date GROUP BY max_as_of_date;

-- Query 4 of 10: Quantify current NADAC exclusions used in the match.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q04_nadac_exclusions` AS
WITH current AS (
  SELECT * FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026`
  WHERE SAFE.PARSE_DATE('%m/%d/%Y', As_of_Date) = (
    SELECT MAX(SAFE.PARSE_DATE('%m/%d/%Y', As_of_Date))
    FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026`
  )
)
SELECT
  COUNT(*) AS current_rows,
  COUNTIF(UPPER(TRIM(OTC)) = 'Y') AS excluded_otc,
  COUNTIF(UPPER(TRIM(Pricing_Unit)) != 'EA') AS excluded_non_ea,
  COUNTIF(NADAC_Per_Unit <= 0 OR NADAC_Per_Unit IS NULL) AS excluded_missing_price,
  COUNTIF(UPPER(TRIM(OTC)) = 'N' AND UPPER(TRIM(Pricing_Unit)) = 'EA' AND NADAC_Per_Unit > 0) AS eligible_current_rows
FROM current;

-- Query 5 of 10: Generate exact normalized name-prefix match candidates.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.match_candidates` AS
WITH cms AS (
  SELECT
    CONCAT(
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(Brnd_Name, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' ')), '|',
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(Gnrc_Name, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' '))
    ) AS drug_key,
    Brnd_Name, Gnrc_Name, Tot_Mftr, Tot_Spndng_2024, Tot_Dsg_Unts_2024,
    Tot_Clms_2024, Tot_Benes_2024,
    TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(Brnd_Name, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' ')) AS brand_norm
  FROM `medication-sourcing-portfolio.med_sourcing.cms_part_d_2024`
  WHERE Mftr_Name = 'Overall' AND COALESCE(Outlier_Flag_2024, 0) = 0
    AND Tot_Spndng_2024 > 0 AND Tot_Dsg_Unts_2024 > 0
), current AS (
  SELECT
    NDC, NDC_Description,
    TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(NDC_Description, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' ')) AS desc_norm,
    NADAC_Per_Unit AS nadac_per_unit,
    Corresponding_Generic_Drug_NADAC_Per_Unit AS generic_nadac_per_unit,
    UPPER(TRIM(Classification_for_Rate_Setting)) AS classification,
    UPPER(TRIM(Pricing_Unit)) AS pricing_unit
  FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026`
  WHERE SAFE.PARSE_DATE('%m/%d/%Y', As_of_Date) = (
    SELECT MAX(SAFE.PARSE_DATE('%m/%d/%Y', As_of_Date))
    FROM `medication-sourcing-portfolio.med_sourcing.nadac_2026`
  ) AND UPPER(TRIM(OTC)) = 'N'
), matched AS (
  SELECT c.*, n.NDC, n.NDC_Description, n.desc_norm, n.nadac_per_unit,
    n.generic_nadac_per_unit, n.classification, n.pricing_unit
  FROM cms c JOIN current n
    ON n.desc_norm = c.brand_norm OR STARTS_WITH(n.desc_norm, CONCAT(c.brand_norm, ' '))
  WHERE LENGTH(c.brand_norm) >= 4
), ea_only AS (
  SELECT drug_key FROM matched GROUP BY drug_key
  HAVING COUNTIF(pricing_unit != 'EA' OR pricing_unit IS NULL) = 0
     AND COUNTIF(pricing_unit = 'EA') > 0
)
SELECT m.* FROM matched m JOIN ea_only USING (drug_key);

-- Query 6 of 10: Calculate brand-to-generic NDC-level reference gaps.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.brand_scenarios` AS
WITH eligible AS (
  SELECT *, 1 - SAFE_DIVIDE(generic_nadac_per_unit, nadac_per_unit) AS gap_rate
  FROM `medication-sourcing-portfolio.med_sourcing.match_candidates`
  WHERE classification IN ('B', 'B-ANDA', 'B-BIO') AND nadac_per_unit > 0
    AND generic_nadac_per_unit > 0 AND generic_nadac_per_unit < nadac_per_unit
), grouped AS (
  SELECT
    drug_key, ANY_VALUE(Brnd_Name) AS brand_name, ANY_VALUE(Gnrc_Name) AS generic_name,
    ANY_VALUE(Tot_Mftr) AS cms_total_manufacturers,
    ANY_VALUE(Tot_Spndng_2024) AS cms_2024_spend,
    ANY_VALUE(Tot_Dsg_Unts_2024) AS cms_2024_dosage_units,
    ANY_VALUE(Tot_Clms_2024) AS cms_2024_claims,
    ANY_VALUE(Tot_Benes_2024) AS cms_2024_beneficiaries,
    COUNT(DISTINCT NDC) AS nadac_ndc_count,
    COUNT(DISTINCT NDC_Description) AS nadac_description_count
  FROM eligible GROUP BY drug_key
), pct AS (
  SELECT DISTINCT drug_key,
    PERCENTILE_CONT(nadac_per_unit, 0.5) OVER (PARTITION BY drug_key) AS nadac_brand_median,
    PERCENTILE_CONT(generic_nadac_per_unit, 0.5) OVER (PARTITION BY drug_key) AS nadac_generic_median,
    PERCENTILE_CONT(gap_rate, 0.25) OVER (PARTITION BY drug_key) AS nadac_ratio_p25,
    PERCENTILE_CONT(gap_rate, 0.5) OVER (PARTITION BY drug_key) AS reference_savings_rate,
    PERCENTILE_CONT(gap_rate, 0.75) OVER (PARTITION BY drug_key) AS nadac_ratio_p75
  FROM eligible
)
SELECT
  g.drug_key, 'Brand-to-generic' AS scenario_type, g.brand_name, g.generic_name,
  g.cms_total_manufacturers, g.cms_2024_spend, g.cms_2024_dosage_units,
  g.cms_2024_claims, g.cms_2024_beneficiaries,
  SAFE_DIVIDE(g.cms_2024_spend, g.cms_2024_dosage_units) AS cms_gross_spend_per_unit,
  g.nadac_ndc_count, g.nadac_description_count, 'EA' AS nadac_pricing_unit,
  p.nadac_brand_median, p.nadac_generic_median, p.nadac_ratio_p25, p.nadac_ratio_p75,
  p.reference_savings_rate,
  g.cms_2024_spend * p.reference_savings_rate AS reference_savings_100pct,
  CAST(NULL AS STRING) AS lowest_cms_manufacturer,
  CAST(NULL AS FLOAT64) AS lowest_cms_mftr_gross_per_unit,
  CAST(NULL AS FLOAT64) AS manufacturer_detail_reconciliation_pct
FROM grouped g JOIN pct p USING (drug_key)
WHERE p.reference_savings_rate > 0 AND p.reference_savings_rate < 1;

-- Query 7 of 10: Calculate the manufacturer-spread proxy after workbook gates.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.manufacturer_scenarios` AS
WITH generic_rows AS (
  SELECT * FROM `medication-sourcing-portfolio.med_sourcing.match_candidates`
  WHERE classification = 'G' AND nadac_per_unit > 0
), generic_stats AS (
  SELECT
    drug_key, ANY_VALUE(Brnd_Name) AS brand_name, ANY_VALUE(Gnrc_Name) AS generic_name,
    ANY_VALUE(Tot_Mftr) AS cms_total_manufacturers,
    ANY_VALUE(Tot_Spndng_2024) AS cms_2024_spend,
    ANY_VALUE(Tot_Dsg_Unts_2024) AS cms_2024_dosage_units,
    ANY_VALUE(Tot_Clms_2024) AS cms_2024_claims,
    ANY_VALUE(Tot_Benes_2024) AS cms_2024_beneficiaries,
    COUNT(DISTINCT NDC) AS nadac_ndc_count,
    COUNT(DISTINCT NDC_Description) AS nadac_description_count
  FROM generic_rows GROUP BY drug_key HAVING COUNT(DISTINCT NDC_Description) = 1
), generic_pct AS (
  SELECT DISTINCT drug_key,
    PERCENTILE_CONT(nadac_per_unit, 0.5) OVER (PARTITION BY drug_key) AS nadac_generic_median
  FROM generic_rows
), generic_match AS (
  SELECT s.*, p.nadac_generic_median FROM generic_stats s JOIN generic_pct p USING (drug_key)
), detail AS (
  SELECT
    CONCAT(
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(Brnd_Name, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' ')), '|',
      TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(REPLACE(REPLACE(Gnrc_Name, '*', ' '), '&', ' AND ')), r'[^A-Z0-9]+', ' '), r'\s+', ' '))
    ) AS drug_key,
    Mftr_Name, Tot_Spndng_2024 AS spend, Tot_Dsg_Unts_2024 AS units,
    SAFE_DIVIDE(Tot_Spndng_2024, Tot_Dsg_Unts_2024) AS gross_per_unit
  FROM `medication-sourcing-portfolio.med_sourcing.cms_part_d_2024`
  WHERE Mftr_Name != 'Overall' AND Tot_Spndng_2024 > 0 AND Tot_Dsg_Unts_2024 > 0
), reconciliation AS (
  SELECT drug_key, SUM(spend) AS detail_spend, SUM(units) AS detail_units
  FROM detail GROUP BY drug_key
), eligible_detail AS (
  SELECT d.*, g.cms_2024_spend, g.cms_2024_dosage_units,
    ROW_NUMBER() OVER (PARTITION BY d.drug_key ORDER BY d.gross_per_unit, d.Mftr_Name) AS price_rank,
    COUNT(DISTINCT d.Mftr_Name) OVER (PARTITION BY d.drug_key) AS eligible_manufacturer_count
  FROM detail d JOIN generic_match g USING (drug_key)
  WHERE d.units >= 1000 AND SAFE_DIVIDE(d.units, g.cms_2024_dosage_units) >= 0.01
)
SELECT
  g.drug_key, 'Manufacturer spread' AS scenario_type, g.brand_name, g.generic_name,
  g.cms_total_manufacturers, g.cms_2024_spend, g.cms_2024_dosage_units,
  g.cms_2024_claims, g.cms_2024_beneficiaries,
  SAFE_DIVIDE(g.cms_2024_spend, g.cms_2024_dosage_units) AS cms_gross_spend_per_unit,
  g.nadac_ndc_count, g.nadac_description_count, 'EA' AS nadac_pricing_unit,
  CAST(NULL AS FLOAT64) AS nadac_brand_median, g.nadac_generic_median,
  CAST(NULL AS FLOAT64) AS nadac_ratio_p25, CAST(NULL AS FLOAT64) AS nadac_ratio_p75,
  1 - SAFE_DIVIDE(e.gross_per_unit, SAFE_DIVIDE(g.cms_2024_spend, g.cms_2024_dosage_units)) AS reference_savings_rate,
  g.cms_2024_spend * (1 - SAFE_DIVIDE(e.gross_per_unit, SAFE_DIVIDE(g.cms_2024_spend, g.cms_2024_dosage_units))) AS reference_savings_100pct,
  e.Mftr_Name AS lowest_cms_manufacturer,
  e.gross_per_unit AS lowest_cms_mftr_gross_per_unit,
  GREATEST(ABS(SAFE_DIVIDE(r.detail_spend, g.cms_2024_spend) - 1), ABS(SAFE_DIVIDE(r.detail_units, g.cms_2024_dosage_units) - 1)) AS manufacturer_detail_reconciliation_pct
FROM generic_match g JOIN eligible_detail e USING (drug_key) JOIN reconciliation r USING (drug_key)
WHERE e.price_rank = 1 AND e.eligible_manufacturer_count >= 2
  AND g.cms_total_manufacturers >= 2 AND STRPOS(g.brand_name, '*') = 0
  AND e.gross_per_unit > 0 AND e.gross_per_unit < SAFE_DIVIDE(g.cms_2024_spend, g.cms_2024_dosage_units)
  AND ABS(SAFE_DIVIDE(r.detail_spend, g.cms_2024_spend) - 1) <= 0.005
  AND ABS(SAFE_DIVIDE(r.detail_units, g.cms_2024_dosage_units) - 1) <= 0.005;

-- Query 8 of 10: Select 25 cases per scenario without overlap.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.selected_50` AS
WITH brand_25 AS (
  SELECT * FROM `medication-sourcing-portfolio.med_sourcing.brand_scenarios`
  QUALIFY ROW_NUMBER() OVER (ORDER BY cms_2024_spend DESC, drug_key) <= 25
), manufacturer_25 AS (
  SELECT m.* FROM `medication-sourcing-portfolio.med_sourcing.manufacturer_scenarios` m
  WHERE NOT EXISTS (SELECT 1 FROM brand_25 b WHERE b.drug_key = m.drug_key)
  QUALIFY ROW_NUMBER() OVER (ORDER BY cms_2024_spend DESC, drug_key) <= 25
), combined AS (
  SELECT * FROM brand_25 UNION ALL SELECT * FROM manufacturer_25
)
SELECT
  FORMAT('MSA-%03d', ROW_NUMBER() OVER (ORDER BY IF(scenario_type = 'Brand-to-generic', 1, 2), cms_2024_spend DESC, drug_key)) AS analysis_id,
  *,
  cms_2024_spend - reference_savings_100pct AS projected_cost_100pct,
  reference_savings_100pct * 0.25 AS savings_25pct_realization,
  reference_savings_100pct * 0.50 AS savings_50pct_realization,
  reference_savings_100pct * 0.75 AS savings_75pct_realization
FROM combined;

-- Query 9 of 10: Produce five realization scenarios.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q09_sensitivity` AS
WITH realization AS (SELECT pct FROM UNNEST([0.00, 0.25, 0.50, 0.75, 1.00]) AS pct)
SELECT
  pct AS realization_rate,
  SUM(s.reference_savings_100pct) * pct AS modeled_savings,
  SUM(s.cms_2024_spend) - SUM(s.reference_savings_100pct) * pct AS modeled_remaining_spend
FROM realization CROSS JOIN `medication-sourcing-portfolio.med_sourcing.selected_50` s
GROUP BY pct ORDER BY pct;

-- Query 10 of 10: Final QA and workbook reconciliation assertions.
CREATE OR REPLACE TABLE `medication-sourcing-portfolio.med_sourcing.q10_qa_assertions` AS
SELECT 'selected row count = 50' AS check_name, COUNT(*) = 50 AS passed,
  CAST(COUNT(*) AS STRING) AS observed, '50' AS expected
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`
UNION ALL
SELECT 'unique drug keys = 50', COUNT(DISTINCT drug_key) = 50,
  CAST(COUNT(DISTINCT drug_key) AS STRING), '50'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`
UNION ALL
SELECT 'scenario split = 25/25',
  COUNTIF(scenario_type = 'Brand-to-generic') = 25 AND COUNTIF(scenario_type = 'Manufacturer spread') = 25,
  FORMAT('%d/%d', COUNTIF(scenario_type = 'Brand-to-generic'), COUNTIF(scenario_type = 'Manufacturer spread')), '25/25'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`
UNION ALL
SELECT 'all reference gaps are positive', COUNTIF(reference_savings_100pct <= 0) = 0,
  CAST(COUNTIF(reference_savings_100pct <= 0) AS STRING), '0 nonpositive rows'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`
UNION ALL
SELECT 'NADAC snapshot = 2026-10-28', max_as_of_date = DATE '2026-10-28',
  CAST(max_as_of_date AS STRING), '2026-10-28'
FROM `medication-sourcing-portfolio.med_sourcing.q03_nadac_snapshot`
UNION ALL
SELECT 'current NADAC NDCs are unique', duplicate_ndc_rows = 0,
  CAST(duplicate_ndc_rows AS STRING), '0 duplicates'
FROM `medication-sourcing-portfolio.med_sourcing.q03_nadac_snapshot`
UNION ALL
SELECT 'manufacturer reconciliation <= 0.5%', MAX(manufacturer_detail_reconciliation_pct) <= 0.005,
  FORMAT('%.12g', MAX(manufacturer_detail_reconciliation_pct)), '<=0.005'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50` WHERE scenario_type = 'Manufacturer spread'
UNION ALL
SELECT 'selected gross Part D spend reconciles to workbook', ABS(SUM(cms_2024_spend) - 22987699551.52) <= 0.01,
  FORMAT('%.2f', SUM(cms_2024_spend)), '22987699551.52'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`
UNION ALL
SELECT '100% reference gap reconciles to workbook', ABS(SUM(reference_savings_100pct) - 17027013774.749456) <= 1.00,
  FORMAT('%.6f', SUM(reference_savings_100pct)), '17027013774.749456 +/- 1.00'
FROM `medication-sourcing-portfolio.med_sourcing.selected_50`;

SELECT * FROM `medication-sourcing-portfolio.med_sourcing.q10_qa_assertions` ORDER BY check_name;
