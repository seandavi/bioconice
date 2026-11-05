#' Connect to a bioc-on-ice release
#'
#' Opens an in-memory DuckDB database and attaches a bioc-on-ice release
#' to it, read-only, over HTTPS. Nothing is downloaded up front: queries
#' read the release's Parquet files, fetching only the columns and row
#' groups they need.
#'
#' After connecting, tables are referenced as `schema.table`, for
#' example `annotation.ncbi__gene` or `clinical.gwas_catalog__association`,
#' in SQL or as `dplyr::tbl(con, I("annotation.ncbi__gene"))`.
#' [bioconice_tables()] lists them with row counts and descriptions, and
#' [bioconice_describe()] documents the columns of one.
#'
#' @section Versions:
#' * `"latest"`: the newest weekly release at
#'   `https://data.bioconice.cancerdatasci.org/latest/`.
#' * `"YYYY-MM-DD"`: a dated weekly release at
#'   `https://data.bioconice.cancerdatasci.org/vYYYY-MM-DD/`. The 4 newest
#'   are kept, about four weeks. Pin one for an analysis you will rerun
#'   soon; [bioconice_release()] tells which date `"latest"` resolved to.
#'
#' Once a month a release is copied to the Hugging Face dataset
#' `seandavis/bioconice` and tagged `YYYY-MM`. Those are kept permanently
#' and are the version to cite; download one and query it locally, see
#' <https://bioconice.cancerdatasci.org/guides/versions-and-citation>.
#'
#' @section Timeouts:
#' Each HTTP request times out after 30 seconds and is retried up to 4
#' times with increasing waits. If connecting still fails,
#' `bioconice_connect()` stops with an error naming the release URL.
#'
#' Requests carry the User-Agent `bioconice/<package version>`. DuckDB
#' extensions (`httpfs`, `json`) are downloaded once and cached in
#' `tools::R_user_dir("bioconice", "cache")`. The connection neither
#' uses `~/.duckdb` nor reads DuckDB secrets persisted there.
#'
#' @param version character(1). `"latest"` (default) or a date
#'   `"YYYY-MM-DD"`. See the Versions section.
#'
#' @return A DuckDB [DBI::DBIConnection-class] with the release attached
#'   as the current database. Close it with [DBI::dbDisconnect()].
#'
#' @examples
#' con <- bioconice_connect()
#' DBI::dbGetQuery(con, "
#'   SELECT gene_id, symbol, description
#'   FROM annotation.ncbi__gene
#'   WHERE symbol = 'TP53' AND taxon_id = 9606")
#' DBI::dbDisconnect(con)
#'
#' @export
bioconice_connect <- function(version = "latest") {
    release_url <- bioconice_release_url(version)
    drv <- duckdb::duckdb(config = list(
        custom_user_agent = paste0(
            "bioconice/", utils::packageVersion("bioconice")
        ),
        allow_persistent_secrets = "false",
        # Setting both directories keeps duckdb away from, and quiet about,
        # ~/.duckdb. Extensions persist so httpfs downloads once per user.
        extension_directory = file.path(
            tools::R_user_dir("bioconice", "cache"), "extensions"
        ),
        secret_directory = file.path(tempdir(), "bioconice-secrets"),
        autoinstall_known_extensions = "true",
        autoload_known_extensions = "true",
        # Bound every request, including manifest.json, so a stalled
        # connection fails instead of hanging; see the Timeouts section.
        http_timeout = "30",
        http_retries = "4",
        http_retry_wait_ms = "1000"
    ))
    con <- DBI::dbConnect(drv)
    ok <- FALSE
    on.exit(if (!ok) DBI::dbDisconnect(con), add = TRUE)

    tryCatch(
        {
            DBI::dbExecute(con, paste0(
                "ATTACH ",
                DBI::dbQuoteString(con, paste0(release_url, "bioconice.duckdb")),
                " AS bioconice (READ_ONLY); USE bioconice;"
            ))
            attr(con, "bioconice_release") <- read_manifest(
                con, version, release_url
            )
        },
        error = function(e) stop_release_error(version, release_url, e)
    )
    ok <- TRUE
    con
}

#' Which bioc-on-ice release a connection is on
#'
#' The release a connection from [bioconice_connect()] points at, with the
#' provenance recorded in its `manifest.json`, and a citation string.
#'
#' @param con A connection from [bioconice_connect()].
#'
#' @return A list: `version` (as passed to [bioconice_connect()]), `url`
#'   (the release folder queried), and from `manifest.json`: `release`
#'   (the release date, `"YYYY-MM-DD"`), `published_at`, `git_sha` (the
#'   commit of the bioc-on-ice pipeline that built it) and `base_url`.
#'   `citation` is a sentence naming the dated release folder, which is
#'   what to record for a result; cite a monthly Hugging Face release
#'   for anything long-lived (see [bioconice_connect()]).
#'
#' @examples
#' con <- bioconice_connect()
#' bioconice_release(con)$citation
#' DBI::dbDisconnect(con)
#'
#' @export
bioconice_release <- function(con) {
    release <- attr(bioconice_con(con), "bioconice_release")
    release[c(
        "version", "url", "release", "published_at", "git_sha", "base_url",
        "citation"
    )]
}

# Everything bioconice_release(), bioconice_tables() and
# bioconice_describe() report, read from the release's manifest.json.
read_manifest <- function(con, version, url) {
    manifest <- paste0(url, "manifest.json")
    header <- DBI::dbGetQuery(con, "
    SELECT release, published_at, git_sha, base_url
    FROM read_json(?, columns = {
        release: 'VARCHAR', published_at: 'VARCHAR',
        git_sha: 'VARCHAR', base_url: 'VARCHAR'
    })", params = list(manifest))
    tables <- DBI::dbGetQuery(con, "
    SELECT t.schema, t.\"table\", t.row_count AS rows, t.comment AS description
    FROM read_json(?), unnest(tables) AS u(t)
    ORDER BY t.schema, t.\"table\"", params = list(manifest))
    # generate_subscripts() keeps the manifest's column order, which a
    # second unnest() in the FROM clause does not.
    columns <- DBI::dbGetQuery(con, "
    SELECT schema, \"table\", c.name AS \"column\", c.type, c.doc
    FROM (
        SELECT t.schema, t.\"table\", unnest(t.columns) AS c,
            generate_subscripts(t.columns, 1) AS pos
        FROM read_json(?), unnest(tables) AS u(t)
    )
    ORDER BY schema, \"table\", pos", params = list(manifest))
    list(
        version = version, url = url,
        release = header$release, published_at = header$published_at,
        git_sha = header$git_sha, base_url = header$base_url,
        citation = sprintf(paste0(
            "bioc-on-ice release %s (git %s), ",
            "https://data.bioconice.cancerdatasci.org/v%s/, accessed %s. ",
            "Monthly archive: https://huggingface.co/datasets/seandavis/bioconice."
        ), header$release, substr(header$git_sha, 1, 7), header$release,
            format(Sys.Date())
        ),
        tables = tibble::as_tibble(tables),
        columns = tibble::as_tibble(columns)
    )
}

# Re-raise an error reading a release with its URL and what to do next.
stop_release_error <- function(version, url, e) {
    msg <- conditionMessage(e)
    hint <- if (grepl("404|does not exist", msg) && version != "latest") {
        paste(
            "Dated releases are kept for about four weeks (the 4 newest).",
            "For older data, download a monthly release from",
            "https://huggingface.co/datasets/seandavis/bioconice;",
            "see https://bioconice.cancerdatasci.org/guides/versions-and-citation."
        )
    }
    stop(
        "Could not read bioc-on-ice release '", version, "' at ", url, ":\n",
        msg, if (!is.null(hint)) c("\n", hint),
        call. = FALSE
    )
}

# Base URL of a release folder; it holds bioconice.duckdb, manifest.json and
# the Parquet files the views read.
bioconice_release_url <- function(version) {
    stopifnot(is.character(version), length(version) == 1L, !is.na(version))
    if (version == "latest") {
        return("https://data.bioconice.cancerdatasci.org/latest/")
    }
    if (grepl("^\\d{4}-\\d{2}-\\d{2}$", version)) {
        return(sprintf("https://data.bioconice.cancerdatasci.org/v%s/", version))
    }
    stop(
        "`version` must be \"latest\" or a date \"YYYY-MM-DD\", not '",
        version, "'.",
        call. = FALSE
    )
}

# Reject anything that is not a connection from bioconice_connect().
bioconice_con <- function(con) {
    if (!inherits(con, "DBIConnection") ||
        is.null(attr(con, "bioconice_release"))) {
        stop("`con` must be a connection from bioconice_connect().",
            call. = FALSE
        )
    }
    con
}
