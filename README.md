# Afterhear apps

The Afterhear apps: Mac (`macapp`), iPhone and Watch (`iosapp`), a small test app (`testapp`)
and the test bench (`bench`). The website, the server and the documents live elsewhere.

Builds run on GitHub Actions:

- **Mac app**: every push to `macapp/` on `dev` publishes the release `mac-test`; on `main`, the
  download linked from the website.
- **iPhone and Watch**, **test app**, **stress test**: by hand, from the Actions tab.
- **Bench**: on every push to `bench/` or to the ranking.

All rights reserved: see [LICENSE](LICENSE).
