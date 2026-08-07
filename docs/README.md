# Documentation site

`index.html` is the KrIO/Kria TDC bring-up reference — board state, boot image
composition, device tree requirements, networking, the DAQ interface, PCIe status,
errata and runbooks. It is a single self-contained file with no external assets, so it
renders correctly from a local checkout as well as from Pages.

## Publishing (no workflow needed)

The simplest route needs nothing but a repository setting:

    Settings -> Pages -> Build and deployment
      Source: Deploy from a branch
      Branch: master (or this branch)   Folder: /docs

The site then appears at `https://<owner>.github.io/SpinQuest-TDC-FW/` and updates on
every push. `.nojekyll` keeps Jekyll from touching the HTML.

## Publishing via Actions (optional)

If you would rather deploy through Actions — useful later if the docs grow a build
step — move the provided workflow into place and set the source accordingly:

    mkdir -p .github/workflows
    git mv docs/pages-workflow.yml .github/workflows/pages.yml

    Settings -> Pages -> Build and deployment -> Source: GitHub Actions

**NOTE:** pushing a file under `.github/workflows/` requires a token with `workflow`
scope, which is why it ships here rather than already installed.

## Editing

Content and styling live in the one file. The palette is defined as custom properties
on `:root` and redefined for dark mode, so change colours there rather than in
individual rules. Keep figures in sync with `ERRATA.md` in the hardware repository —
where the two disagree, the hardware repo is the source of truth for board issues and
this page is the source of truth for firmware and bring-up.
