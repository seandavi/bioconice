# Contributing to bioconice

- **A bug in the package** (connect, tables, an error message): open an issue
  here with the code, `sessionInfo()`, `packageVersion("duckdb")`, and the
  release (`bioconice_release(con)$release`).
- **A problem in the data** (wrong values, a missing source): open it on
  [bioc-on-ice](https://github.com/seandavi/bioc-on-ice/issues), where the
  data is built.
- **Code:** one issue, one pull request (`Closes #N`).
  `rcmdcheck::rcmdcheck(args = "--no-manual")` passes with 0 errors and 0
  warnings. New behaviour comes with a test.

This project follows the [Contributor Covenant](../CODE_OF_CONDUCT.md).
