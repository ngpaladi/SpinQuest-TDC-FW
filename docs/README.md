# Documentation site

`index.html` is the KrIO/Kria TDC bring-up reference — board state, boot image
composition, device tree requirements, networking, the DAQ interface, PCIe status,
errata and runbooks. It is a single self-contained file with no external assets, so it
renders correctly from a local checkout as well as from Pages.

## Publishing

Pages is configured to deploy this folder directly, with no build step or workflow:

    Settings -> Pages -> Build and deployment
      Source: Deploy from a branch
      Branch: krio-ethernet-netboot    Folder: /docs

Every push to that branch rebuilds the site, usually within a minute. `.nojekyll`
keeps Jekyll from touching the HTML.

**NOTE:** the account has a verified custom domain, so the site is served at
<https://www.noahpaladino.com/SpinQuest-TDC-FW/> rather than at `github.io`. The
`github.io` address still resolves and redirects. This repository is public, so the
page is public — worth remembering before adding anything you would not put on a
public site.

Once this branch merges, change **Branch** to `master` in the same setting. Nothing
else needs to move.

## Editing

Content and styling live in the one file. The palette is defined as custom properties
on `:root` and redefined for dark mode, so change colours there rather than in
individual rules. Keep figures in sync with `ERRATA.md` in the hardware repository —
where the two disagree, the hardware repo is the source of truth for board issues and
this page is the source of truth for firmware and bring-up.
