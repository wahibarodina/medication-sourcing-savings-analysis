# Medication Sourcing Savings Analysis

Independent portfolio project using public CMS data. Not implemented in any organization.

## Question

For 50 high-spend Medicare Part D drugs, how large is the price gap a buyer could target by (A) switching brand drugs to their generic equivalents and (B) consolidating purchases to the lowest-cost manufacturer of the same generic?

## Result

The 50 selected drugs account for **$22.99 billion** of 2024 gross Medicare Part D claim cost.

| Scenario | 100% reference gap |
|---|---|
| Brand-to-generic (25 drugs) | $16.56B |
| Manufacturer spread (25 drugs) | $0.46B |
| **Total** | **$17.03B** |

| Realization case | Modeled gap |
|---|---|
| 25% | $4.26B |
| 50% | $8.51B |
| 75% | $12.77B |

Three brands (Farxiga, Entresto, Januvia) account for about 68% of the total gap.

These are reference-price gaps, not forecast savings. They should not be used for budgeting without NDC-level utilization, net cost, rebate, formulary, supply and contract data.

## Data

| Source | Version | Role |
|---|---|---|
| [CMS Medicare Part D Spending by Drug](https://data.cms.gov/sites/default/files/2026-06/98218f98-166c-4723-8438-c344a4ef96a6/DSD_PTD_RY26_P04_V10_DY24_BGM.csv) | 2024 data year, 14,536 rows | Volume and gross spend |
| [NADAC weekly file](https://download.medicaid.gov/data/nadac-national-average-drug-acquisition-cost-10-28-2026.csv) | Snapshot as of 2026-10-28, 27,541 current NDCs | Acquisition-cost reference by NDC |

`source_manifest.csv` lists access dates, file sizes and SHA-256 hashes.

**Definitions that matter:**
- CMS spending is gross claim cost across all payers. It excludes rebates and is not pharmacy acquisition cost.
- NADAC is a national average retail pharmacy acquisition cost from survey data. It is not a guaranteed purchase price and has no manufacturer field.

## Method

**Avoiding double counting.** The CMS file has one `Overall` row per drug plus manufacturer detail rows. Drug totals use `Overall` rows only. Manufacturer rows are used only to measure price spread, and they must reconcile to the `Overall` row within 0.5% (maximum observed variance: effectively zero).

**Matching rules.** Latest NADAC snapshot only; non-OTC; pricing unit `EA`; positive price; exact normalized name-prefix match (no fuzzy matching); CMS outlier-flagged rows excluded.

**Scenario A: brand to generic.** For each brand, the gap rate is the median of NDC-level ratios `1 − (corresponding generic NADAC ÷ brand NADAC)`, applied to CMS gross spend.

**Scenario B: manufacturer spread.** For multi-manufacturer generics with one current NADAC description, compare the overall gross spend per unit to the lowest eligible manufacturer (at least 1% of units and 1,000 units). This is a proxy, not a manufacturer-specific acquisition-cost comparison.

**Selection.** 25 drugs per scenario, ranked by 2024 spend, with no drug in both groups.

**Sensitivity.** The 100% gap is scaled at 0%, 25%, 50%, 75% and 100% realization. No probabilities are assigned.

## Quality checks

- 50 rows, 50 unique drugs, 25 per scenario, no overlap
- All modeled gaps positive
- Every match uses the `EA` pricing unit
- One NADAC row per NDC in the current snapshot
- Manufacturer detail reconciles to totals within 0.5%

## Limitations

- CMS has no NDC, strength, form or route; NADAC has no manufacturer. No row is an exact manufacturer-specific match.
- Periods differ: CMS spend is 2024, NADAC prices are a 2026 snapshot. Several generics (e.g. Farxiga, Entresto, Januvia) launched after 2024, so part of this gap may already be captured.
- Brand gaps use unweighted NDC ratios because NDC-level Part D volume isn't public.
- Some manufacturer spreads may reflect strength or form mix rather than true price differences.
- Rebates, contracts, formulary, clinical equivalence and supply are not modeled.

## Files

| File | Contents |
|---|---|
| `Medication Sourcing Savings Analysis.xlsx` | Formula-linked model: summary, sensitivity, analysis, match QA, matched NDCs, manufacturer detail, sources |
| `Medication Sourcing Memo.pdf` | One-page sourcing memo |
| `medication_sourcing_analysis_bigquery.sql` | 10 commented queries in BigQuery Standard SQL |
| `analysis_50_drugs.csv` | Final 50-drug analysis table |
| `source_manifest.csv` | Source URLs, dates and file hashes |

## Tools

Excel, SQL (BigQuery Standard SQL), Python. Built with AI assistance; I reviewed the methods and QA checks and can walk through each step.
