test_that("bioconice_release_url maps versions to release folders", {
    expect_equal(
        bioconice_release_url("latest"),
        "https://data.bioconice.cancerdatasci.org/latest/"
    )
    expect_equal(
        bioconice_release_url("2026-11-01"),
        "https://data.bioconice.cancerdatasci.org/v2026-11-01/"
    )
    expect_error(bioconice_release_url("2026-11"), "must be")
    expect_error(bioconice_release_url("v2026-11-01"), "must be")
    expect_error(bioconice_release_url(NA_character_))
    expect_error(bioconice_release_url(c("latest", "latest")))
})

test_that("read_manifest parses a manifest.json", {
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con))
    dir <- paste0(test_path("fixtures"), "/")
    release <- read_manifest(con, "2026-11-04", dir)
    expect_equal(release$version, "2026-11-04")
    expect_equal(release$url, dir)
    expect_equal(release$release, "2026-11-04")
    expect_equal(release$published_at, "2026-11-04T16:29:53+00:00")
    expect_equal(release$git_sha, "a577def1ffbd4677334ee72bb8e1b32c793e3915")
    expect_equal(
        release$base_url, "https://data.bioconice.cancerdatasci.org/latest"
    )
    expect_match(
        release$citation,
        "release 2026-11-04 \\(git a577def\\), .*/v2026-11-04/, accessed"
    )
    expect_named(release$tables, c("schema", "table", "rows", "description"))
    expect_equal(release$tables$schema, c("annotation", "clinical"))
    expect_equal(release$tables$rows, c(73664629, 1203708))
    expect_match(release$tables$description[1], "^Genes as NCBI Gene")
    expect_named(release$columns, c("schema", "table", "column", "type", "doc"))
    expect_equal(nrow(release$columns), 6L)
})

test_that("stop_release_error names the URL and suggests what to do", {
    err <- function(msg, version = "2026-01-01") {
        tryCatch(
            stop_release_error(version, "https://x/", simpleError(msg)),
            error = conditionMessage
        )
    }
    expect_match(err("HTTP 404 Not Found"), "release '2026-01-01' at https://x/")
    expect_match(err("HTTP 404 Not Found"), "huggingface.co/datasets/seandavis/bioconice")
    expect_match(err("database does not exist"), "four weeks")
    expect_no_match(err("HTTP 404 Not Found", "latest"), "four weeks")
    expect_no_match(err("timed out"), "four weeks")
})

test_that("helpers reject things that are not bioconice connections", {
    expect_error(bioconice_release("latest"), "must be a connection")
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con))
    expect_error(bioconice_tables(con), "must be a connection")
    expect_error(bioconice_describe(con, "x.y"), "must be a connection")
    expect_error(bioconice_tbl(con, "x.y"), "must be a connection")
})

test_that("bioconice_tbl reads a manifest table lazily and rejects others", {
    skip_if_not_installed("dplyr")
    skip_if_not_installed("dbplyr")
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con))
    # A connection shaped like bioconice_connect()'s, with the fixture's
    # annotation.ncbi__gene as a real table so the query can run offline.
    attr(con, "bioconice_release") <- read_manifest(
        con, "2026-11-04", paste0(test_path("fixtures"), "/")
    )
    DBI::dbExecute(con, "
    CREATE SCHEMA annotation;
    CREATE TABLE annotation.ncbi__gene AS
    SELECT * FROM (VALUES ('7157', 9606, 'TP53'), ('22059', 10090, 'Trp53'))
        AS t(gene_id, taxon_id, symbol)")
    lazy <- bioconice_tbl(con, "annotation.ncbi__gene")
    expect_s3_class(lazy, "tbl_lazy")
    out <- lazy |>
        dplyr::filter(symbol == "TP53", taxon_id == 9606L) |>
        dplyr::select(gene_id, symbol) |>
        dplyr::collect()
    expect_equal(out$gene_id, "7157")
    expect_error(bioconice_tbl(con, "ncbi__gene"), "schema-qualified")
    expect_error(bioconice_tbl(con, "annotation.nope"), "No table")
    expect_error(bioconice_tbl(con, c("a.b", "c.d")))
})

test_that("bioconice_connect attaches the latest release", {
    skip_on_cran()
    skip_if_offline()
    con <- bioconice_connect()
    on.exit(DBI::dbDisconnect(con))
    expect_equal(
        DBI::dbGetQuery(con, "SELECT current_database() AS db")$db, "bioconice"
    )
    tp53 <- DBI::dbGetQuery(con, "
    SELECT gene_id, symbol FROM annotation.ncbi__gene
    WHERE symbol = 'TP53' AND taxon_id = 9606")
    expect_equal(tp53$gene_id, "7157")
    ua <- DBI::dbGetQuery(
        con, "SELECT current_setting('custom_user_agent') AS ua"
    )$ua
    expect_equal(ua, paste0("bioconice/", utils::packageVersion("bioconice")))
    ext_dir <- DBI::dbGetQuery(
        con, "SELECT current_setting('extension_directory') AS d"
    )$d
    cache <- tools::R_user_dir("bioconice", "cache")
    expect_equal(ext_dir, file.path(cache, "extensions"))
    expect_equal(
        DBI::dbGetQuery(con, "SELECT count(*) AS n FROM duckdb_secrets()")$n, 0
    )

    release <- bioconice_release(con)
    expect_named(release, c(
        "version", "url", "release", "published_at", "git_sha", "base_url",
        "citation"
    ))
    expect_equal(release$version, "latest")
    expect_match(release$release, "^\\d{4}-\\d{2}-\\d{2}$")
    expect_match(release$git_sha, "^[0-9a-f]{40}$")
    expect_match(release$citation, release$release, fixed = TRUE)

    tables <- bioconice_tables(con)
    expect_named(tables, c("schema", "table", "rows", "description"))
    expect_true("ncbi__gene" %in% tables$table[tables$schema == "annotation"])
    expect_true("gwas_catalog__association" %in%
        tables$table[tables$schema == "clinical"])
    expect_true(all(tables$rows > 0))
    # Every manifest table is a view in the attached database.
    views <- DBI::dbGetQuery(con, "
    SELECT table_schema AS schema, table_name AS \"table\"
    FROM information_schema.tables WHERE table_catalog = current_database()")
    expect_setequal(
        paste(tables$schema, tables$table),
        paste(views$schema, views$table)
    )

    cols <- bioconice_describe(con, "annotation.ncbi__gene")
    expect_named(cols, c("column", "type", "doc"))
    expect_true(all(c("gene_id", "taxon_id", "symbol") %in% cols$column))
    expect_error(bioconice_describe(con, "ncbi__gene"), "schema-qualified")
})

test_that("bioconice_tbl reads a schema-qualified view of a release", {
    skip_on_cran()
    skip_if_offline()
    skip_if_not_installed("dplyr")
    skip_if_not_installed("dbplyr")
    con <- bioconice_connect()
    on.exit(DBI::dbDisconnect(con))
    out <- bioconice_tbl(con, "annotation.ncbi__gene") |>
        dplyr::filter(symbol == "TP53", taxon_id == 9606L) |>
        dplyr::select(gene_id, symbol) |>
        dplyr::collect()
    expect_equal(out$gene_id, "7157")
})

test_that("bioconice_connect pins a dated release", {
    skip_on_cran()
    skip_if_offline()
    latest <- bioconice_connect()
    date <- bioconice_release(latest)$release
    DBI::dbDisconnect(latest)
    con <- bioconice_connect(date)
    on.exit(DBI::dbDisconnect(con))
    release <- bioconice_release(con)
    expect_equal(release$version, date)
    expect_equal(release$release, date)
    expect_equal(release$url, bioconice_release_url(date))
    # The dated folder's views read its own Parquet files, not latest/.
    sql <- DBI::dbGetQuery(con, "
    SELECT sql FROM duckdb_views()
    WHERE schema_name = 'annotation' AND view_name = 'gene'")$sql
    expect_match(sql, paste0("/v", date, "/"), fixed = TRUE)
})

test_that("bioconice_connect explains an aged-out dated release", {
    skip_on_cran()
    skip_if_offline()
    expect_error(bioconice_connect("2000-01-01"), "four weeks")
})
