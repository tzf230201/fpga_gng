# Webpage materials

All website sources and assets are kept in this folder.

```text
web_page/
  index.html                       Project page
  styles.css                       Project page styles
  images/                          Website images and README figures
  publication_materials/           Paper, poster, figures, and research sources
    dataset_two_moons.csv           Two Moons experiment dataset
    dataset_concentric_circle.csv   Concentric Circles experiment dataset
    published/                     Website copies of publication downloads and figures
  slidev/                          Presentation sources and npm dependencies
  WEB_VERSION_SCIENTIFIC_STUDY.md    Web feasibility report
  out/                             Generated website, ignored by Git
```

The paper, poster, figures, and research sources are kept in `publication_materials/`. Its `published/` subfolder contains the files served on the website at `publication_materials/`. Update these copies when publishing revised research materials.

The [Two Moons CSV](publication_materials/dataset_two_moons.csv) and [Concentric Circles CSV](publication_materials/dataset_concentric_circle.csv) are copied from `publication_materials/experiment_logs/` and published alongside the paper and poster. The original Concentric Circles source is named `dataset_concentric_circles.csv`.

## Build and preview

From the repository root, run these commands in PowerShell:

```powershell
npm --prefix web_page/slidev ci
New-Item -ItemType Directory -Path web_page/out, web_page/out/publication_materials -Force | Out-Null
Copy-Item -Path web_page/index.html, web_page/styles.css, web_page/README.md, web_page/WEB_VERSION_SCIENTIFIC_STUDY.md, web_page/images -Destination web_page/out -Recurse -Force
Copy-Item -Path web_page/publication_materials/published/* -Destination web_page/out/publication_materials -Recurse -Force
Copy-Item -Path web_page/publication_materials/dataset_two_moons.csv, web_page/publication_materials/dataset_concentric_circle.csv -Destination web_page/out/publication_materials -Force
npm --prefix web_page/slidev run build -- --base /slides/ --out ../out/slides
python -m http.server 8000 --directory web_page/out
```

Open <http://localhost:8000/> for the project page and <http://localhost:8000/slides/> for the presentation.

For presentation development, run `npm --prefix web_page/slidev run dev` from the repository root.

The presentation follows the supplied conference PowerPoint, with current experiment values and figures from this project. See `web_page/slidev/README.md` in the repository for its sources, click sequences, and demonstration videos.

## GitHub Pages

The workflow in `.github/workflows/deploy-slidev.yml` copies the project page and assets from this folder, builds the presentation with `npm run build:gh`, and uploads `web_page/out/`. The published URLs remain `/fpga_gng/` and `/fpga_gng/slides/`.
