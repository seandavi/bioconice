#' List the tables of a bioc-on-ice release
#'
#' @inheritParams bioconice_release
#'
#' @return A tibble with one row per table: `schema`, `table`, `rows`
#'   (row count) and `description`, as recorded in the release's
#'   `manifest.json`. Query a table as `schema.table`.
#'
#' @examples
#' con <- bioconice_connect()
#' bioconice_tables(con)
#' DBI::dbDisconnect(con)
#'
#' @export
bioconice_tables <- function(con) {
    attr(bioconice_con(con), "bioconice_release")$tables
}

#' Describe the columns of a bioc-on-ice table
#'
#' @inheritParams bioconice_release
#' @param table character(1). A table name, schema-qualified as in
#'   `"annotation.ncbi__gene"`. [bioconice_tables()] lists them.
#'
#' @return A tibble with one row per column: `column`, `type` (the DuckDB
#'   type) and `doc`, as recorded in the release's `manifest.json`.
#'
#' @examples
#' con <- bioconice_connect()
#' bioconice_describe(con, "annotation.ncbi__gene")
#' DBI::dbDisconnect(con)
#'
#' @export
bioconice_describe <- function(con, table) {
    id <- bioconice_table(con, table)
    columns <- attr(con, "bioconice_release")$columns
    hit <- columns$schema == id$schema & columns$table == id$table
    columns[hit, c("column", "type", "doc")]
}

#' A dplyr table for a bioc-on-ice table
#'
#' A lazy [dplyr::tbl()] on one table of the release, for `dplyr::filter()`,
#' `dplyr::select()`, joins and `dplyr::collect()`. Needs the dplyr and
#' dbplyr packages.
#'
#' Use this rather than `dplyr::tbl(con, "schema.table")`: how dplyr
#' resolves a schema-qualified name on a DuckDB connection differs between
#' duckdb versions, and a name that is not in the release fails here with
#' a clear error rather than at `collect()`.
#'
#' @inheritParams bioconice_describe
#'
#' @return A lazy table (`tbl_lazy`) reading `table`.
#'
#' @examples
#' con <- bioconice_connect()
#' bioconice_tbl(con, "annotation.ncbi__gene") |>
#'     dplyr::filter(symbol == "TP53", taxon_id == 9606L) |>
#'     dplyr::select(gene_id, symbol, description) |>
#'     dplyr::collect()
#' DBI::dbDisconnect(con)
#'
#' @export
bioconice_tbl <- function(con, table) {
    id <- bioconice_table(con, table)
    for (pkg in c("dplyr", "dbplyr")) {
        if (!requireNamespace(pkg, quietly = TRUE)) {
            stop("bioconice_tbl() needs the ", pkg, " package; ",
                "install.packages(\"", pkg, "\").",
                call. = FALSE
            )
        }
    }
    # Passing SQL, not a name, keeps dplyr::tbl() from probing the catalog
    # for it; that probe is what differs between duckdb 1.x and 2.x.
    from <- DBI::dbQuoteIdentifier(
        con, DBI::Id(schema = id$schema, table = id$table)
    )
    dplyr::tbl(con, dbplyr::sql(paste("SELECT * FROM", from)))
}

# The manifest row (schema, table) for a schema-qualified table name, or an
# error naming the table if the release does not have it.
bioconice_table <- function(con, table) {
    stopifnot(is.character(table), length(table) == 1L, !is.na(table))
    tables <- attr(bioconice_con(con), "bioconice_release")$tables
    hit <- paste(tables$schema, tables$table, sep = ".") == table
    if (!any(hit)) {
        stop(
            "No table '", table, "' in this release. ",
            "Use a schema-qualified name from bioconice_tables().",
            call. = FALSE
        )
    }
    tables[hit, c("schema", "table")]
}
