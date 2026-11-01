# Medication Sourcing Savings Analysis

## Purpose

This portfolio project screens 50 Medicare Part D drug keys for two standardized sourcing scenarios using official CMS and Medicaid.gov data:

- 25 brand-to-generic reference-price cases
- 25 manufacturer-spread proxy cases

The analysis is designed to demonstrate healthcare data sourcing, grain inspection, cross-source matching, financial scenario modeling, quality assurance, SQL design, spreadsheet modeling, and executive communication.

It does **not** claim realized savings, negotiated prices, BigQuery execution, or Tableau publication.

## Executive result

The selected 50 drug keys represent **$22.99 billion** of 2024 gross Medicare Part D claim cost. The unconstrained 100% reference gap is **$17.03 billion**:

- Brand-to-generic reference gap: **$16.56 billion**
- Manufacturer-spread proxy gap: **$0.46 billion**
- 25% realization case: **$4.26 billion**
- 50% realization case: **$8.51 billion**
- 75% realization case: **$12.77 billion**

These are mechanical scenarios. The large result is driven by high-spend brand drugs with substantially lower corresponding generic NADAC reference prices as of October 2026. It is not a forecast and should not be used for budgeting without NDC-level utilization, net cost, formulary, rebate, supply, and contract data.

## Source data

### Medicare Part D Spending by Drug

- Official current CSV: `data/raw/cms_part_d_spending_by_drug_2024.csv`
- Latest year: 2024
- Rows: 14,536
- Columns: 46
- Grain: one `Overall` row per brand/generic drug key plus manufacturer detail rows
- Main measures: gross Part D spending, dosage units, claims, beneficiaries, and weighted spending per dosage unit
- Important definition: total spending reflects gross prescription claim cost across Medicare, plans, beneficiaries, and other payors. It excludes manufacturer rebates and other price concessions. It is **not** pharmacy acquisition cost.

### NADAC 2026

- Official current weekly file: `data/raw/nadac_2026_through_2026-10-28.csv`
- Full-file rows: 1,298,476
- Latest `As of Date`: 2026-10-28
- Current-snapshot rows: 27,541
- Current unique NDCs: 27,541
- Grain: one row per NDC in the current weekly snapshot
- Main measures: NADAC per unit, effective date, pricing unit, OTC flag, rate-setting classification, and corresponding generic NADAC
- Important definition: NADAC is a national average acquisition-cost reference based on retail community pharmacy survey data. It is not a guaranteed purchase price and contains no manufacturer-name field.

See `data/source_manifest.csv` for official URLs, access dates, file sizes, and SHA-256 hashes.

## Grain and double-counting controls

The CMS file contains both `Overall` and manufacturer detail rows. Adding them together would double count the same drug. The project therefore uses:

- `Overall` rows for drug-level spend and utilization totals
- Manufacturer detail rows only to measure within-drug gross-spend-per-unit spread
- A reconciliation test requiring the sum of manufacturer detail rows to agree with the `Overall` row within 0.5%

The maximum reconciliation variance among the 25 selected manufacturer scenarios was effectively zero (`2.49e-11` as a proportion).

The brand-to-generic and manufacturer groups are mutually exclusive. The final dataset contains 50 rows and 50 unique drug keys, with no overlap between scenario groups.

## Matching method

### Shared eligibility rules

1. Use the latest NADAC snapshot (`As of Date = 2026-10-28`).
2. Exclude OTC records.
3. Require the NADAC pricing unit to be `EA`.
4. Require a positive NADAC price.
5. Match CMS product name to NADAC description using an exact normalized name prefix, not fuzzy matching.
6. Exclude CMS 2024 outlier-flagged rows.

### Brand-to-generic scenario

For each eligible brand:

1. Retain NADAC rows classified as `B`, `B-ANDA`, or `B-BIO` with a positive corresponding generic NADAC.
2. Calculate the NDC-level reference gap:

   `1 - corresponding generic NADAC / brand NADAC`

3. Use the unweighted median NDC-level gap for the CMS drug key.
4. Apply that rate to the CMS 2024 gross Part D spend:

   `reference gap = CMS gross spend x median NADAC gap rate`

This reduces mixing across strengths compared with dividing two separately aggregated medians, but it still cannot reproduce the actual CMS strength/NDC mix.

### Manufacturer-spread scenario

For each eligible multi-manufacturer CMS drug:

1. Require the current NADAC match to have one unique NDC description to reduce strength/form ambiguity.
2. Exclude CMS names marked with `*`, which CMS uses for drugs whose average unit spending reflects multiple routes.
3. Reconcile manufacturer detail to the `Overall` row.
4. Require a manufacturer row to represent at least 1% of overall dosage units and at least 1,000 dosage units.
5. Calculate observed CMS gross spend per dosage unit for each manufacturer row.
6. Compare the overall gross-spend-per-unit to the lowest eligible manufacturer row.

This is a **manufacturer-spread proxy**, not a manufacturer acquisition-cost comparison. NADAC does not identify manufacturers, and CMS manufacturer rows may still reflect unobserved product-mix differences.

## Sensitivity

Sensitivity scales the 100% reference gap at 0%, 25%, 50%, 75%, and 100%. It does not assign probabilities or model market conversion, contracting timing, clinical appropriateness, supply constraints, rebates, or implementation costs.

## Quality assurance

Automated checks in `qa/` confirm:

- Exactly 50 selected rows
- 50 unique drug keys
- 25 cases per scenario
- No overlap between scenarios
- Positive modeled reference gaps
- `EA` pricing unit for every selected match
- Current NADAC snapshot date of 2026-10-28
- Manufacturer detail reconciliation within 0.5%
- No current-snapshot duplicate NDC rows
- Source-file hashes recorded

The workbook also includes formula-error scans, formula/value inspections, and rendered previews of every worksheet.

## Deliverables

The following project files are available in this public GitHub repository:

- [Excel Financial Model](Medication%20Sourcing%20Savings%20Analysis.xlsx) — Formula-linked workbook containing medication-level analysis, sensitivity scenarios, quality-control checks, and charts.
- [Executive Sourcing Memo](Medication%20Sourcing%20Memo.pdf) — One-page executive summary of findings, modeled opportunities, methodology, and limitations.
- [BigQuery SQL Scripts](medication_sourcing_analysis_bigquery.sql) — 10 documented BigQuery Standard SQL queries covering data profiling, matching, scenario analysis, and validation.
- [50-Drug Analysis Dataset](analysis_50_drugs.csv) — Processed dataset containing the 50 selected medication cases.
- [Source Manifest](source_manifest.csv) — Documentation of official data sources, access dates, and source-file hashes.

**Additional validation:** The original analysis package also contains supporting matching evidence, manufacturer detail, and QA records that are not currently included in this public repository.

## BigQuery and Tableau status

- The SQL is written for BigQuery Standard SQL but **was not executed in BigQuery**. Table names are explicit placeholders and must be replaced after loading the official CSVs.
- No Tableau workbook was requested as a final deliverable, and nothing was published to Tableau.

## Reproduction

1. Confirm the source files and hashes in `data/source_manifest.csv`.
2. Run `src/build_analysis.py` with the bundled Python runtime to rebuild processed data and QA.
3. Run `src/build_workbook.mjs` with the bundled workspace Node runtime and `@oai/artifact-tool` to rebuild the Excel file.
4. Run `src/build_memo.py` with the bundled Python runtime to rebuild the memo.
5. Review rendered workbook and PDF previews in `qa/` before use.

## Limitations and required next data

The central limitation is that CMS and NADAC do not share a defensible exact join key at the grain used here:

- CMS has no NDC, strength, dosage form, route, or package field.
- NADAC is NDC-level but has no manufacturer name.
- CMS gross spending is not acquisition cost and excludes confidential drug-specific rebates.
- Manufacturer-level CMS dosage units are available, but they may represent different strength/form mixes and cannot be tied to NADAC manufacturer prices.
- The periods are not aligned: CMS is calendar 2024 and NADAC is a 2026 snapshot.
- The brand/generic gap uses unweighted current NDC ratios because NDC-level Part D volume is unavailable.

Before business use, obtain NDC-level utilization and package/strength mix, actual net acquisition cost, rebate and formulary terms, manufacturer/labeler crosswalks, availability and supply constraints, clinical equivalence review, and aligned-period pricing.

## Guide availability

The referenced uploaded guide (`Project Guide Medication Sourcing Savings Analysis.pdf`) was not available at `/mnt/data`, in the project workspace, or in the referenced conversation attachment list. This package follows the phases and deliverables stated in the user request and the supplied official source links. It does not claim fidelity to inaccessible guide text.
