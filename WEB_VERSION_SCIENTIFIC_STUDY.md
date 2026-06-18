# Scientific Report: Feasibility and Design of a Web Version for the FPGA GNG Repository

## Abstract

Repository `fpga_gng` secara teknis sangat memungkinkan untuk dibuat menjadi versi web. Berdasarkan inspeksi struktur project, repo ini sudah memiliki beberapa komponen pendukung web, yaitu presentasi Slidev di folder `slidev`, workflow GitHub Pages di `.github/workflows/deploy-slidev.yml`, aset gambar eksperimen, paper WCCI/IJCNN, log CSV, visualisasi Processing, firmware C, dan implementasi VHDL untuk FPGA. Namun, versi web yang ideal tidak boleh dipahami hanya sebagai "menaruh file GitHub di browser". Project ini adalah sistem hardware-software co-design untuk Growing Neural Gas (GNG) pada FPGA, sehingga versi webnya sebaiknya dibagi menjadi beberapa lapisan: dokumentasi ilmiah statis, presentasi interaktif, replay hasil eksperimen, simulator GNG berbasis browser, dan bila diperlukan dashboard hardware-in-the-loop melalui Web Serial API.

Kesimpulan utama laporan ini adalah: versi web dapat dibuat, dan bahkan sebagian infrastrukturnya sudah tersedia. Jalur paling aman adalah membangun website statis dari Slidev/GitHub Pages untuk publikasi paper, dokumentasi, hasil eksperimen, dan poster. Jalur lanjutan adalah membuat dashboard web interaktif yang dapat memuat dataset CSV, menggambar node-edge GNG, menghitung Quantization Error (QE) dan Topological Error (TE), serta melakukan replay snapshot UART. Jalur paling ambisius adalah menghubungkan browser langsung ke board FPGA melalui Web Serial API sehingga visualisasi Processing dapat dipindahkan ke web.

## Keywords

FPGA, Growing Neural Gas, NEORV32, Web Version, GitHub Pages, Slidev, Web Serial API, scientific visualization, reproducibility, hardware-software co-design, fixed-point arithmetic, edge-cell graph encoding.

## 1. Pendahuluan

Project ini mengembangkan implementasi Growing Neural Gas pada perangkat FPGA kecil seperti Sipeed Tang Nano 9K. GNG adalah algoritma self-organizing clustering yang belajar secara online dari data tanpa label. Berbeda dari metode clustering statis, GNG mempertahankan graph yang dapat bertambah node, membuat atau menghapus edge, dan memperbarui posisi node berdasarkan aliran data.

Karena project ini menyentuh beberapa domain sekaligus, yaitu machine learning, embedded system, VHDL, RISC-V firmware, UART visualization, dan paper akademik, versi webnya harus didesain sebagai media reproduksibilitas ilmiah. Website tidak hanya menampilkan halaman promosi, tetapi harus membantu pembaca memahami:

1. Masalah ilmiah yang diselesaikan.
2. Desain algoritma GNG pada keterbatasan FPGA.
3. Struktur hardware dan firmware.
4. Hasil eksperimen dan metrik evaluasi.
5. Cara menjalankan ulang eksperimen.
6. Cara melihat hasil secara interaktif.
7. Hubungan antara paper, source code, bitstream, firmware, dan visualisasi.

Dengan kata lain, versi web harus menjadi "research companion" untuk repository, bukan sekadar halaman depan.

## 2. Evidence from Current Repository

Inspeksi repo menunjukkan bahwa versi web bukan dimulai dari nol. Komponen berikut sudah tersedia:

| Komponen | Lokasi | Fungsi terhadap versi web |
|---|---|---|
| Slidev presentation | `slidev/slides.md` | Presentasi ilmiah yang bisa dibuild menjadi static web |
| GitHub Pages workflow | `.github/workflows/deploy-slidev.yml` | Deploy otomatis Slidev ke GitHub Pages |
| Root web file | `index.html` | Ada, tetapi saat ini berisi path lokal Windows sehingga tidak siap deploy |
| Paper WCCI/IJCNN | `WCCI2026_5/main.tex` | Sumber narasi ilmiah dan hasil eksperimen |
| Poster/PDF/PPTX | `WCCI2026_5/` | Materi publikasi yang bisa ditampilkan/diunduh di web |
| Hasil eksperimen gambar | `images/`, `WCCI2026_5/*.png` | Visualisasi topology, training progress, dataset |
| Log eksperimen CSV | `WCCI2026_5/experiment_logs/`, `gng_neorv32_accelerator_V2/processing_gng_dataset/logs/` | Sumber replay dan validasi hasil |
| VHDL FPGA GNG | `gng_neorv32_accelerator_V2/gng_gowin_project/src/gng.vhd` | Implementasi hardware full GNG/FSM |
| NEORV32 firmware | `gng_neorv32_accelerator_V3/fw/main.c` | Implementasi CPU GNG dengan CFS winner finder |
| Processing visualizer | `processing_gng_dataset/*.pde`, `processing_gng_replay/*.pde` | Basis untuk migrasi visualisasi ke web |

Temuan penting adalah file `index.html` root saat ini bukan hasil build static yang portable. File itu menunjuk ke path lokal seperti `/@fs/C:/Users/HP/Documents/Github/...`, yang umumnya adalah output dev server lokal, bukan artefak produksi. Untuk GitHub Pages, yang benar adalah membuild `slidev` menjadi folder `dist` dengan base path `/fpga_gng/`, seperti yang sudah dirancang dalam workflow.

## 3. Scientific Context

### 3.1 Growing Neural Gas

Growing Neural Gas memodelkan distribusi data sebagai graph adaptif. Setiap node menyimpan vektor bobot, sedangkan edge menyimpan hubungan topologis antara node. Pada setiap iterasi, algoritma mengambil satu sampel input, mencari node pemenang pertama dan kedua, menggerakkan pemenang dan tetangganya, memperbarui usia edge, menghapus edge yang terlalu tua, serta menyisipkan node baru berdasarkan error akumulatif.

Secara konseptual, GNG cocok untuk edge AI karena:

1. Bersifat online.
2. Tidak memerlukan label.
3. Dapat beradaptasi terhadap struktur data.
4. Memiliki representasi graph yang dapat divisualisasikan.
5. Dapat dievaluasi dengan metrik kuantitatif seperti QE dan TE.

Namun, GNG juga sulit dijalankan pada FPGA kecil karena struktur graph dinamis dan perhitungan jarak biasanya menggunakan floating-point. Project ini menyelesaikan masalah tersebut melalui fixed-point/integer arithmetic, edge-cell encoding, static memory allocation, dan FSM/accelerator berbasis BRAM.

### 3.2 Hardware Constraint

Target seperti Tang Nano 9K memiliki resource terbatas. Berdasarkan paper lokal di `WCCI2026_5/main.tex`, konfigurasi yang digunakan mencakup:

| Item | Nilai |
|---|---|
| FPGA | Sipeed Tang Nano 9K, Gowin GW1NR-9C |
| Clock | 27 MHz |
| Bahasa hardware | VHDL |
| Node maksimum pada desain full FPGA | 40 |
| Dataset contoh | Two Moons dan Concentric Circles |
| UART | 1 Mbit/s |
| Edge encoding | upper-triangular edge-cell age+1 |
| Arithmetic | integer/fixed-point |

Desain ini relevan secara ilmiah karena memindahkan algoritma graph-learning dari lingkungan komputer umum ke hardware kecil dengan memory bounded dan latency deterministik.

## 4. Problem Statement for the Web Version

Pertanyaan utama:

> Apakah repository FPGA GNG dapat dibuat menjadi versi web yang ilmiah, dapat diakses publik, dan mendukung reproduksibilitas eksperimen?

Pertanyaan turunan:

1. Apakah presentasi dan paper dapat dipublikasikan sebagai website statis?
2. Apakah hasil eksperimen dapat divisualisasikan ulang di browser?
3. Apakah simulator GNG dapat dibuat di browser tanpa FPGA?
4. Apakah browser dapat berkomunikasi langsung dengan board FPGA?
5. Apakah website dapat menjaga hubungan antara source code, data, metode, dan hasil?

Hipotesis:

1. Website statis dapat dibuat dengan risiko rendah karena repo sudah memakai Slidev dan GitHub Actions.
2. Replay eksperimen dapat dibuat dengan risiko menengah karena data CSV dan gambar hasil sudah tersedia.
3. Simulator browser dapat dibuat dengan risiko menengah karena GNG 2D dapat diimplementasikan ulang di JavaScript/TypeScript.
4. Hardware-in-the-loop browser dapat dibuat dengan risiko lebih tinggi karena bergantung pada Web Serial API, browser support, format frame UART, dan izin user.

## 5. Feasibility Analysis

### 5.1 Static Research Website

Ini adalah opsi paling realistis untuk tahap pertama. Website statis dapat berisi:

1. Halaman utama project.
2. Ringkasan kontribusi ilmiah.
3. Link paper, poster, slides, dan GitHub.
4. Visualisasi hasil Two Moons dan Concentric Circles.
5. Dokumentasi build firmware.
6. Dokumentasi flash FPGA/NEORV32/PicoTiny.
7. Penjelasan edge-cell encoding.
8. Penjelasan fixed-point arithmetic.
9. Halaman reproducibility.

Feasibility: sangat tinggi.

Alasan:

1. Folder `slidev` sudah ada.
2. `slidev/package.json` sudah memiliki script `build:gh`.
3. `.github/workflows/deploy-slidev.yml` sudah mengupload `slidev/dist` ke GitHub Pages.
4. README sudah mengarah ke `https://tzf230201.github.io/fpga_gng/`.

Masalah yang perlu diperbaiki:

1. `index.html` root saat ini tidak portable.
2. Beberapa teks README/slidev terlihat mengalami encoding issue.
3. Website masih berbentuk presentasi, belum menjadi dokumentasi multi-halaman.

### 5.2 Interactive Experiment Replay

Replay eksperimen berarti browser membaca log snapshot node/edge atau CSV hasil eksperimen, lalu menggambar ulang evolusi graph GNG. Ini dapat dibuat tanpa hardware FPGA.

Data yang dapat dipakai:

1. `gng_nodes_*.csv`
2. `gng_edges_*.csv`
3. `gng_dbg_*.csv`
4. `dataset_*.csv`
5. Gambar hasil eksperimen sebagai baseline visual.

Fitur replay:

1. Pilih dataset: Two Moons atau Concentric Circles.
2. Pilih epoch/snapshot.
3. Render sample, node, edge.
4. Tampilkan node count dan edge count.
5. Hitung QE dan TE.
6. Tampilkan grafik training dynamics.

Feasibility: tinggi-menengah.

Risiko:

1. Format CSV perlu distandarisasi.
2. Log dari beberapa versi project mungkin berbeda.
3. Perlu parser yang robust.

### 5.3 Browser-Based GNG Simulator

Simulator browser akan menjalankan algoritma GNG langsung di JavaScript/TypeScript. Ini berguna untuk demonstrasi tanpa FPGA. Simulasi tidak menggantikan hasil hardware, tetapi memberi pembaca pengalaman interaktif.

Fitur simulator:

1. Generate dataset Two Moons, Concentric Circles, Gaussian clusters.
2. Atur parameter `Nmax`, `lambda`, `epsilon_w`, `epsilon_n`, `alpha`, `beta`, `max_age`.
3. Jalankan step-by-step.
4. Tampilkan graph node-edge secara real time.
5. Bandingkan float simulation dengan fixed-point approximation.
6. Export hasil ke CSV.

Feasibility: menengah.

Catatan ilmiah:

Simulator harus diberi label jelas sebagai "software reference", bukan bukti hardware. Validasi harus dilakukan dengan membandingkan hasil simulator dengan snapshot FPGA untuk dataset dan seed yang sama.

### 5.4 Hardware-in-the-Loop Web Dashboard

Dashboard ini memungkinkan browser terhubung langsung ke board melalui serial port. Secara teknis, browser modern berbasis Chromium mendukung Web Serial API. User dapat memilih port COM, mengirim dataset ke board, menerima frame node/edge, dan melihat visualisasi real-time.

Arsitektur:

```text
Browser UI
  -> Web Serial API
  -> USB UART / COM port
  -> NEORV32 firmware atau FPGA UART receiver
  -> GNG training
  -> UART frame node/edge/profiling
  -> Browser parser
  -> Canvas/SVG visualization
```

Feasibility: menengah-tinggi, tetapi lebih sensitif terhadap environment.

Kendala:

1. Web Serial API tidak didukung semua browser.
2. Browser harus berjalan pada `https://` atau `localhost`.
3. User harus memberikan izin port serial secara manual.
4. Parser frame harus cocok dengan protokol firmware/FPGA.
5. Error handling serial harus baik agar tidak freeze.

Keuntungan:

1. Processing visualizer dapat digantikan oleh web.
2. Demo menjadi lebih mudah untuk konferensi.
3. Tidak perlu instal Processing untuk visualisasi dasar.
4. Data eksperimen dapat direkam langsung dari browser.

### 5.5 Cloud Synthesis or Online Build

Membuat website yang bisa mensintesis VHDL Gowin secara online tidak direkomendasikan untuk tahap awal.

Alasan:

1. Toolchain Gowin EDA memiliki dependensi dan lisensi tersendiri.
2. Build FPGA berat untuk server publik.
3. GitHub Pages tidak mendukung backend compute.
4. Security risk tinggi jika menerima input HDL dari user.

Alternatif lebih baik:

1. Website menyediakan instruksi build.
2. Website menyediakan artefak hasil build jika memang boleh dibagikan.
3. GitHub Actions hanya dipakai untuk build web, bukan sintesis FPGA.

## 6. Proposed Web Architecture

### 6.1 Recommended Architecture

Versi web sebaiknya dibuat bertahap:

```text
fpga_gng/
  slidev/                 existing presentation
  web/                    optional future interactive app
  docs/                   optional static documentation
  WCCI2026_5/             paper, poster, figures
  images/                 public visual assets
  experiment_logs/        curated logs for replay
```

Untuk tahap pertama, cukup gunakan `slidev` sebagai website utama. Untuk tahap berikutnya, buat `web/` berbasis Vite/React atau plain TypeScript jika ingin dashboard interaktif.

### 6.2 Static Site Layer

Layer ini berisi narasi ilmiah:

1. Abstract project.
2. Motivation.
3. Algorithm.
4. Hardware architecture.
5. Memory optimization.
6. Results.
7. Reproducibility.
8. Publication assets.

Teknologi:

1. Slidev untuk presentasi.
2. GitHub Pages untuk deployment.
3. Markdown untuk konten.

Command lokal:

```bash
cd slidev
npm ci
npm run dev
```

Build untuk GitHub Pages:

```bash
cd slidev
npm run build:gh
```

### 6.3 Visualization Layer

Layer visualisasi dapat memakai Canvas 2D atau SVG.

Canvas lebih cocok untuk:

1. Banyak titik dataset.
2. Animasi cepat.
3. Replay real-time.

SVG lebih cocok untuk:

1. Jumlah node sedikit.
2. Interaksi klik node/edge.
3. Export visual sebagai vector.

Untuk GNG dengan `Nmax` 20 sampai 40, SVG cukup nyaman. Untuk replay banyak titik atau animasi dense, Canvas lebih aman.

### 6.4 Data Layer

Data web harus dikurasi agar ringan. Tidak semua log besar perlu dimasukkan ke website. Cukup pilih dataset dan snapshot penting:

1. Two Moons final result.
2. Two Moons training progress.
3. Concentric Circles final result.
4. Concentric Circles training progress.
5. Beberapa log snapshot untuk replay.

Format ideal:

```json
{
  "dataset": "two_moons",
  "epoch": 32,
  "nodes": [
    {"id": 0, "x": -0.4, "y": 0.3, "active": true, "degree": 2}
  ],
  "edges": [
    {"source": 0, "target": 1, "age": 4}
  ],
  "metrics": {
    "qe": 0.1832,
    "te": 0.0
  }
}
```

JSON lebih mudah untuk web daripada CSV mentah, tetapi CSV tetap dapat disediakan sebagai data mentah untuk reproducibility.

### 6.5 Hardware Serial Layer

Untuk dashboard live, parser harus mendukung protokol yang ada:

1. Firmware NEORV32 V3 memakai frame dengan header `0xFF 0xFF`, command, length, payload, checksum.
2. Full FPGA VHDL V2 memakai TLV/debug frame seperti `A5 10`, node snapshot `A5 20`, dan edge snapshot `A5 21`.
3. Processing visualizer saat ini dapat menjadi referensi format.

Web parser sebaiknya dibuat modular:

```text
SerialReader
  -> FrameDecoder
      -> NEORV32FrameParser
      -> FPGAFullGNGFrameParser
  -> StateStore
  -> Renderer
  -> MetricsPanel
```

Dengan cara ini, variasi protokol antar versi repo tidak membuat UI perlu ditulis ulang.

## 7. Scientific Validation Plan

Website yang baik untuk project ilmiah harus menampilkan bukan hanya visual, tetapi juga validasi. Validasi dapat dibagi menjadi tiga kategori.

### 7.1 Algorithmic Validation

Tujuan: memastikan hasil web simulator atau replay konsisten dengan algoritma GNG.

Metrik:

1. Quantization Error.
2. Topological Error.
3. Node count.
4. Edge count.
5. Training convergence.
6. Final topology.

Prosedur:

1. Jalankan dataset Two Moons dengan seed tetap.
2. Jalankan dataset Concentric Circles dengan seed tetap.
3. Bandingkan final node/edge dari FPGA, Python reference, dan web simulator.
4. Hitung deviasi QE/TE.
5. Dokumentasikan perbedaan akibat fixed-point, integer scaling, dan ordering sample.

### 7.2 Hardware Validation

Tujuan: memastikan website tidak mengklaim performa yang tidak terbukti hardware.

Metrik:

1. Cycles per sample.
2. Microseconds per sample.
3. Samples per second.
4. UART frame rate.
5. Resource utilization: LUT, FF, BRAM, DSP.

Data dari paper lokal menunjukkan contoh hasil:

| Dataset | Cycles/sample | us/sample | Samples/s |
|---|---:|---:|---:|
| Two Moons | sekitar 16,852 | sekitar 624.1 | sekitar 1,602 |
| Concentric Circles | sekitar 16,931 | sekitar 627.1 | sekitar 1,595 |

Website harus menampilkan metrik ini sebagai hasil hardware, bukan hasil simulasi browser.

### 7.3 Web Validation

Tujuan: memastikan versi web dapat dipakai pembaca.

Metrik:

1. Website berhasil load dari GitHub Pages.
2. Semua gambar muncul.
3. Link paper/poster bekerja.
4. Slidev route bekerja dengan base path `/fpga_gng/`.
5. Dashboard replay dapat membaca dataset/log.
6. Jika memakai Web Serial, browser dapat connect, disconnect, dan recover dari frame corrupt.

## 8. Recommended Implementation Roadmap

### Phase 1: Stabilize Existing GitHub Pages

Target: website presentasi ilmiah dapat dibuka publik.

Task:

1. Gunakan workflow `.github/workflows/deploy-slidev.yml`.
2. Pastikan GitHub repository mengaktifkan Pages dari GitHub Actions.
3. Jalankan build lokal `npm run build:gh`.
4. Hapus atau ganti root `index.html` yang masih menunjuk path lokal.
5. Perbaiki encoding text di `README.md` dan `slidev/slides.md`.
6. Pastikan gambar di `slidev/public/images/` sesuai path.

Output:

1. Website presentasi.
2. URL publik GitHub Pages.
3. README yang link-nya benar.

### Phase 2: Create Scientific Documentation Page

Target: website tidak hanya slide, tetapi juga dokumentasi ilmiah.

Task:

1. Tambahkan halaman "Method".
2. Tambahkan halaman "Hardware Architecture".
3. Tambahkan halaman "Results".
4. Tambahkan halaman "Reproducibility".
5. Tambahkan download link untuk paper/poster.

Output:

1. Dokumentasi yang dapat dibaca tanpa membuka paper PDF.
2. Narasi ilmiah yang cocok untuk pembaca konferensi.

### Phase 3: Add Experiment Replay

Target: pembaca dapat melihat ulang evolusi GNG.

Task:

1. Kurasi CSV snapshot.
2. Convert CSV ke JSON ringan.
3. Buat renderer node-edge.
4. Buat timeline slider epoch.
5. Tambahkan panel metrik.

Output:

1. Replay web untuk Two Moons.
2. Replay web untuk Concentric Circles.

### Phase 4: Add Browser Simulator

Target: pembaca dapat mencoba GNG tanpa hardware.

Task:

1. Implementasi GNG float reference di TypeScript.
2. Tambahkan fixed-point approximation mode.
3. Tambahkan kontrol hyperparameter.
4. Tambahkan perbandingan hasil dengan snapshot hardware.

Output:

1. Interactive GNG simulator.
2. Dataset generator.
3. Export hasil.

### Phase 5: Add Web Serial Hardware Dashboard

Target: browser menjadi pengganti Processing visualizer.

Task:

1. Implement Web Serial connect/disconnect.
2. Implement parser frame UART.
3. Implement live plot.
4. Implement data recording.
5. Tambahkan dokumentasi browser support.

Output:

1. Live FPGA dashboard.
2. Conference demo yang lebih portable.

## 9. Risk Analysis

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Root `index.html` tidak portable | Website rusak di GitHub Pages | Deploy dari `slidev/dist`, bukan file dev lokal |
| Encoding rusak di README/slide | Tampilan tidak profesional | Normalisasi UTF-8 dan cek rendering |
| Log CSV tidak konsisten | Replay gagal | Buat schema JSON canonical |
| Web simulator berbeda dari FPGA | Klaim ilmiah bias | Label simulator sebagai reference dan validasi terhadap snapshot |
| Web Serial tidak didukung browser tertentu | User tidak bisa live demo | Sediakan replay offline sebagai fallback |
| Data terlalu besar untuk static site | Load lambat | Kurasi log dan compress JSON |
| GitHub Pages base path salah | Asset 404 | Gunakan `--base /fpga_gng/` |
| Hardware build tidak bisa di web | User berekspektasi salah | Jelaskan bahwa sintesis FPGA tetap lokal/offline |

## 10. Recommended Website Content Structure

Struktur navigasi yang disarankan:

```text
Home
  - Project summary
  - Key results
  - Links to paper, slides, GitHub

Method
  - GNG algorithm
  - Edge-cell encoding
  - Fixed-point arithmetic
  - FSM/NEORV32 architecture

Results
  - Two Moons
  - Concentric Circles
  - QE/TE
  - Runtime and resource usage

Interactive
  - Replay from FPGA logs
  - Browser simulator
  - Optional Web Serial live mode

Reproducibility
  - Toolchain setup
  - Build firmware
  - Flash board
  - Run dataset
  - Regenerate figures

Publication
  - Paper PDF
  - Poster PDF/PPTX
  - Citation
```

## 11. Minimal Technical Plan for This Repository

Jika ingin hasil cepat, langkah paling pragmatis adalah:

1. Pakai `slidev` sebagai web utama.
2. Perbaiki teks dan gambar pada `slidev/slides.md`.
3. Pastikan workflow GitHub Pages aktif.
4. Ganti root `index.html` dengan halaman sederhana yang redirect/link ke build Pages, atau hapus jika tidak digunakan.
5. Tambahkan halaman/section "Web Scientific Report" berdasarkan dokumen ini.
6. Setelah website statis stabil, baru buat dashboard interaktif.

Command validasi lokal:

```bash
cd slidev
npm ci
npm run build:gh
```

Jika ingin preview lokal:

```bash
cd slidev
npm run dev
```

## 12. Why a Web Version Matters Scientifically

Versi web meningkatkan nilai ilmiah project karena:

1. Reproducibility lebih mudah: pembaca dapat melihat data, hasil, dan prosedur dalam satu tempat.
2. Accessibility lebih tinggi: paper, poster, slide, dan visualisasi tidak tersebar.
3. Demonstrability lebih kuat: algoritma GNG dapat dilihat bergerak, bukan hanya dijelaskan.
4. Hardware contribution lebih jelas: pembaca dapat membedakan Python reference, firmware NEORV32, dan full FPGA datapath.
5. Review akademik lebih mudah: reviewer dapat memverifikasi claim memory, topology, dan runtime melalui visualisasi dan data.

Untuk paper conference seperti WCCI/IJCNN, website semacam ini dapat berfungsi sebagai supplementary material. Hal ini penting karena keterbatasan halaman paper sering membuat detail implementasi, instruksi build, dan dataset tidak muat.

## 13. Conclusion

Repo `fpga_gng` bisa dibuat menjadi versi web, dan sebagian fondasinya sudah ada. Jalur paling benar adalah membangun website statis dari `slidev` melalui GitHub Pages, lalu menambahkan dokumentasi ilmiah dan visualisasi hasil eksperimen. File root `index.html` saat ini tidak dapat dianggap sebagai versi web produksi karena masih merujuk path lokal development. Workflow GitHub Actions yang sudah ada jauh lebih tepat karena membuild `slidev` menjadi artefak static.

Secara ilmiah, versi web paling bernilai jika tidak hanya menampilkan slide, tetapi juga menyajikan hasil eksperimen, metrik QE/TE, resource utilization, runtime, dan replay graph GNG. Tahap lanjutan dapat mencakup simulator browser dan Web Serial dashboard untuk board FPGA. Dengan desain bertahap ini, website dapat berkembang dari dokumentasi publik menjadi platform demonstrasi dan reproduksibilitas untuk hardware-software co-design GNG pada FPGA.

Rekomendasi akhir:

1. Buat web statis dulu dengan Slidev dan GitHub Pages.
2. Perbaiki portable build dan encoding.
3. Tambahkan halaman dokumentasi ilmiah.
4. Tambahkan replay eksperimen dari log.
5. Tambahkan Web Serial hanya setelah format frame stabil.

Dengan pendekatan tersebut, versi web dapat dibuat secara realistis tanpa mengganggu source FPGA dan tetap menjaga integritas ilmiah project.

## References

1. Fritzke, B. "A Growing Neural Gas Network Learns Topologies." Advances in Neural Information Processing Systems, 1995.
2. Kohonen, T. "Self-Organized Formation of Topologically Correct Feature Maps." Biological Cybernetics, 1982.
3. NEORV32 project documentation and source code, used as RISC-V soft-core reference in this repository.
4. Project paper source: `WCCI2026_5/main.tex`.
5. Project Slidev source: `slidev/slides.md`.
6. Project deployment workflow: `.github/workflows/deploy-slidev.yml`.
7. Project FPGA full GNG implementation: `gng_neorv32_accelerator_V2/gng_gowin_project/src/gng.vhd`.
8. Project NEORV32 firmware/CFS implementation: `gng_neorv32_accelerator_V3/fw/main.c`.
