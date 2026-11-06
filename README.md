# bioconice

<!-- badges: start -->
[![R-CMD-check](https://github.com/seandavi/bioconice/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/seandavi/bioconice/actions/workflows/R-CMD-check.yaml)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

> **Bioconductor annotation without the packages.**

[bioc-on-ice](https://bioconice.cancerdatasci.org) publishes the data behind
Bioconductor's OrgDb, TxDb and EnsDb packages, plus GO and other ontologies,
orthologs, interactions, pathways, GWAS Catalog associations and literature
links, as weekly releases of Parquet tables. Every species and every source
sit in one release. `bioconice` attaches a release to DuckDB, read-only over
HTTPS, so you query it with SQL or `dplyr`. Nothing to install per organism,
nothing to download, and a release you can pin by date.

## Install

``` r
install.packages("pak")
pak::pak("seandavi/bioconice")
```

CRAN has `duckdb` binaries for Windows and macOS. On Linux it compiles from
source unless your repository serves binaries (for example
[Posit Public Package Manager](https://packagemanager.posit.co/)).

## Three queries

``` r
library(bioconice)
con <- bioconice_connect()   # a plain DuckDB DBI connection, ~2 s
```

### 1. Gene lookup across species, no org.*.eg.db

``` r
bioconice_tbl(con, "annotation.ncbi__gene") |>
  dplyr::filter(symbol %in% c("TP53", "Trp53", "Tp53"),
                taxon_id %in% c(9606, 10090, 10116)) |>
  dplyr::select(taxon_id, gene_id, symbol, description, map_location) |>
  dplyr::collect()
#> # A tibble: 3 × 5
#>   taxon_id gene_id symbol description                       map_location
#>      <int> <chr>   <chr>  <chr>                             <chr>
#> 1     9606 7157    TP53   tumor protein p53                 17p13.1
#> 2    10090 22059   Trp53  transformation related protein 53 11 B3|11 42.83 cM
#> 3    10116 24842   Tp53   tumor protein p53                 10q24
```

Their GO annotations (OrgDb's `GO` table) are in `annotation.ncbi__gene_go`:

``` r
DBI::dbGetQuery(con, "
  SELECT taxon_id, count(DISTINCT go_id) AS go_terms,
         count(DISTINCT go_id) FILTER (evidence = 'IDA') AS direct_assay
  FROM annotation.ncbi__gene_go
  WHERE gene_id IN ('7157', '22059', '24842')
  GROUP BY taxon_id ORDER BY taxon_id")
#>   taxon_id go_terms direct_assay
#> 1     9606      131           58
#> 2    10090      196           36
#> 3    10116      211            8
```

### 2. Gene models without a TxDb

Transcripts and exons from Ensembl, for human TP53:

``` r
DBI::dbGetQuery(con, "
  SELECT t.transcript_id, t.biotype, t.canonical,
         count(*) AS exons, min(e.start) AS start, max(e.\"end\") AS \"end\"
  FROM annotation.transcript t
  JOIN annotation.exon e USING (transcript_id, taxon_id, source)
  WHERE t.gene_id = 'ENSG00000141510' AND t.taxon_id = 9606
  GROUP BY ALL ORDER BY canonical DESC, exons DESC, transcript_id LIMIT 5")
#>     transcript_id        biotype canonical exons   start     end
#> 1 ENST00000269305 protein_coding      TRUE    11 7668421 7687490
#> 2 ENST00000420246 protein_coding     FALSE    12 7668404 7687538
#> 3 ENST00000455263 protein_coding     FALSE    12 7668404 7687538
#> 4 ENST00000503591 protein_coding     FALSE    12 7668421 7687538
#> 5 ENST00000610538 protein_coding     FALSE    12 7668404 7687481
```

`annotation.exon` also carries `cds_start`, `cds_end`, `cds_phase`, `strand`
and `rank`, so it stands in for TxDb's exon, cds and splicing tables.

### 3. GWAS Catalog

``` r
DBI::dbGetQuery(con, "
  SELECT snps, mapped_gene, p_value, study_accession
  FROM clinical.gwas_catalog__association
  WHERE mapped_trait = 'breast carcinoma'
  ORDER BY pvalue_mlog DESC LIMIT 5")
#>         snps mapped_gene p_value study_accession
#> 1 rs35054928       FGFR2  2E-322      GCST004988
#> 2  rs2981578       FGFR2  2E-291    GCST90090980
#> 3  rs2981578       FGFR2  1E-245      GCST004988
#> 4  rs4784227      CASC16  2E-240    GCST90090980
#> 5  rs4784227      CASC16  7E-201      GCST004988
```

`snp_ids`, `snp_gene_ids` and `mapped_trait_ids` are DuckDB lists: find a
gene's associations with
`WHERE list_contains(snp_gene_ids, 'ENSG00000141510')`. Flat bridge tables
for them are coming
([bioc-on-ice#264](https://github.com/seandavi/bioc-on-ice/issues/264)).

## Pin a release

`"latest"` changes weekly. For an analysis you will rerun, connect to the
dated release it resolved to:

``` r
bioconice_release(con)$release
#> [1] "2026-11-04"
con <- bioconice_connect("2026-11-04")
```

Dated releases are kept for about four weeks (the 4 newest). For anything
longer-lived, download the monthly release from the Hugging Face dataset
[seandavis/bioconice](https://huggingface.co/datasets/seandavis/bioconice)
and query it locally; see
[Versions and citation](https://bioconice.cancerdatasci.org/guides/versions-and-citation).

## What is in a release

``` r
bioconice_tables(con)
#> # A tibble: 81 × 4
#>    schema     table                           rows description
#>    <chr>      <chr>                          <dbl> <chr>
#>  1 annotation cellosaurus__cell_line        169026 Cell lines as Cellosaurus re…
#>  2 annotation cellosaurus__disease          124906 Diseases of the donor a cell…
#>  3 annotation cellosaurus__xref             473381 Cellosaurus' cross-reference…
#>  4 annotation complexportal__complex         21829 Macromolecular complexes fro…
#>  5 annotation complexportal__participant    108060 Members of each Complex Port…
#>  6 annotation exon                       143333679 Exons in transcript context,…
#>  7 annotation gene                         7419569 Genes, stacked across annota…
#>  8 annotation hgnc__gene                     45289 Human gene nomenclature as H…
#>  9 annotation icite__citation            931611343 The PubMed citation graph as…
#> 10 annotation icite__metrics              41170023 iCite's citation metrics for…
#> # ℹ 71 more rows

bioconice_describe(con, "clinical.gwas_catalog__association")
#> # A tibble: 27 × 3
#>    column                    type      doc
#>    <chr>                     <chr>     <chr>
#>  1 association_key           VARCHAR   "md5 of the nine curated columns — study…
#>  2 study_accession           VARCHAR   "GWAS Catalog study accession; joins cli…
#>  3 snps                      VARCHAR   "The variant: an rsID on most rows, othe…
#>  4 snp_ids                   VARCHAR[] "The individual variants in snps, split …
#> # ℹ 23 more rows
```

Schemas: `annotation` (genes, transcripts, exons, GO, orthologs, identifier
mappings, interactions, pathways, literature), `clinical` (GWAS Catalog),
`ontology` (GO, EFO, MONDO, DOID, CL, UBERON terms and relationships),
`reference` (genomes), `resource` (pointers to CELLxGENE, ENCODE, BEDbase and
eQTL Catalogue datasets), `provenance` (source versions) and `raw` (each
source as published). The
[Explorer](https://bioconice.cancerdatasci.org/explorer/) browses the same
tables in the browser.

## Citing and licences

``` r
bioconice_release(con)$citation
#> [1] "bioc-on-ice release 2026-11-04 (git a577def), https://data.bioconice.cancerdatasci.org/v2026-11-04/, accessed 2026-11-05. Monthly archive: https://huggingface.co/datasets/seandavis/bioconice."
```

Each source keeps its own licence. Where a source declares one, the table's
description (`bioconice_tables(con)$description`) names it, and
`provenance.release` records the version and URL of each source a release was
built from. Cite the sources you use as they ask. The `bioconice` package
itself is MIT.

## Coming

OrgDb, TxDb and EnsDb generators that build the native Bioconductor objects
from a release
([bioc-on-ice#265](https://github.com/seandavi/bioc-on-ice/issues/265)).

## Functions

| Function | Returns |
|---|---|
| `bioconice_connect(version)` | A DuckDB DBI connection with the release's views attached |
| `bioconice_tbl(con, table)` | A lazy `dplyr` table on one `schema.table` |
| `bioconice_tables(con)` | Tables with row counts and descriptions |
| `bioconice_describe(con, table)` | Columns, types and docs of a table |
| `bioconice_release(con)` | Release date, `git_sha`, URLs and a citation string |

The data pipeline, schema docs and ADRs live in
[seandavi/bioc-on-ice](https://github.com/seandavi/bioc-on-ice). Funded by
NCI ITCR award U24CA289073.
