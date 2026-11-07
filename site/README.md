# Writers Block site

Two static pages, no build step, no scripts, no external fonts:

- `index.html` — home page
- `privacy.html` — privacy policy

## Serving it

Any static host works: upload the `site/` folder as the web root.

For GitHub Pages note that "Deploy from a branch" only offers `/ (root)` or
`/docs` as the folder, not `/site`. To serve this folder from `main`, either
publish with a GitHub Actions workflow (`actions/upload-pages-artifact` with
`path: site`, then `actions/deploy-pages`; source set to "GitHub Actions" in
Settings → Pages) or move the two files to `docs/` and pick `/docs`. Nothing is
enabled yet; this folder is a draft.

With Pages enabled for the `OBEYPALANTIR/RhymeAI` repository the URLs are:

- Home page: `https://obeypalantir.github.io/RhymeAI/`
- Privacy policy: `https://obeypalantir.github.io/RhymeAI/privacy.html`

## Google Auth Platform → Branding

Paste into the OAuth consent screen's Branding page:

| Field | Value |
| --- | --- |
| Application home page | `https://obeypalantir.github.io/RhymeAI/` |
| Application privacy policy link | `https://obeypalantir.github.io/RhymeAI/privacy.html` |
| Authorized domain | `obeypalantir.github.io` |

If the site is served from a custom domain instead, use that domain in all
three fields.

## Keeping the policy true

`privacy.html` describes what the apps do today (see `docs/CLOUD_BACKUP_SETUP.md`
and `PARITY.md`). Update it, and its changelog line, whenever backup, sync, AI
providers, the model host or data collection change.
