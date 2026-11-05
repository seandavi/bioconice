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
    stopifnot(is.character(table), length(table) == 1L, !is.na(table))
    columns <- attr(bioconice_con(con), "bioconice_release")$columns
    hit <- paste(columns$schema, columns$table, sep = ".") == table
    if (!any(hit)) {
        stop(
            "No table '", table, "' in this release. ",
            "Use a schema-qualified name from bioconice_tables().",
            call. = FALSE
        )
    }
    columns[hit, c("column", "type", "doc")]
}
