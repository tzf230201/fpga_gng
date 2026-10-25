# Conference presentation

The Slidev deck follows the content and teaching sequence of the supplied `FPGA GNG.pptx`: GNG and its applications, FPGA fundamentals, parallel computation, GNG implementation, experiments, and future applications.

Repeated PowerPoint animation steps are combined into click sequences on the arithmetic-lane slides. Five embedded demonstration videos are available with playback controls, including three supplementary demos after the closing slide.

The current project webpage and `../publication_materials/main.tex` supply the implementation parameters, result figures, memory comparison, FPGA utilization, and runtime measurements. The 3D arithmetic examples explain scheduling; the measured FPGA experiments use 2D datasets. Parallel winner search remains future work.

From the repository root:

```powershell
npm --prefix web_page/slidev run dev
npm --prefix web_page/slidev run build:gh
```

The GitHub Pages build writes to `web_page/out/slides/`. See [the webpage guide](../README.md) to preview the complete site, including the paper and dataset downloads.

`style.css` controls slide typography and layout. `public/reference/` contains the supplied presentation's figures and web-compatible videos. `public/images/` contains project result and application figures. Source references and image credits appear in the relevant speaker notes.
