#!/usr/bin/env node
// Rasterise the artwork to exactly the sizes Nexus asks for.
//
//     npm run images
//
// Writes into publish/images/, which is gitignored: the SVGs are the source and the PNGs are
// build output. Regenerate rather than committing them, so a change to the design language
// cannot leave a stale PNG on a mod page.
//
// WHY A SCRIPT AND NOT A README FULL OF COMMANDS. The sizes are not decoration — Nexus crops a
// header that is not 1300x372 and downscales a gallery image that is not 1920x1080, and the
// second one matters because these images are mostly TEXT. A command someone retypes with a
// wrong -w is a blurry code panel on the mod page. The numbers live here once.
//
// The gallery cards are authored at 1280x720 and rendered at 1920x1080: same 16:9, and SVG is
// vector, so that is a clean 1.5x with no resampling. The header is authored at its final size
// because 3.5:1 is a different composition, not the banner squashed.
import { Resvg } from '@resvg/resvg-js';
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';

const OUT = 'publish/images';

// [ source, width, height, output, what it is for ]
const JOBS = [
  ['assets/header.svg', 1300, 372, 'header.png', 'Nexus "Header" — the banner across the top'],
  ['assets/logo.svg', 512, 512, 'thumbnail.png', 'square mark, for anywhere small'],
  ['assets/banner.svg', 1280, 640, 'banner.png', 'wide mark, for GitHub social preview'],
];

for (const f of readdirSync('assets/gallery').filter((n) => n.endsWith('.svg')).sort()) {
  JOBS.push([
    join('assets/gallery', f),
    1920,
    1080,
    basename(f, '.svg') + '.png',
    'Nexus "Images" gallery',
  ]);
}

mkdirSync(OUT, { recursive: true });

let bytes = 0;
for (const [src, w, h, out, why] of JOBS) {
  const svg = readFileSync(src, 'utf8');
  // fitTo width: the viewBox aspect decides the height, so a mismatch would show up as a
  // wrong number below rather than as a silently letterboxed image.
  const png = new Resvg(svg, {
    fitTo: { mode: 'width', value: w },
    font: { loadSystemFonts: true },
  })
    .render()
    .asPng();

  writeFileSync(join(OUT, out), png);
  bytes += png.length;

  // Read the size back out of the PNG header rather than trusting the request.
  const gotW = png.readUInt32BE(16);
  const gotH = png.readUInt32BE(20);
  const ok = gotW === w && gotH === h;
  console.log(
    `  ${ok ? 'OK  ' : 'SIZE'} ${out.padEnd(26)} ${gotW}x${gotH}` +
      (ok ? '' : `  EXPECTED ${w}x${h}`) +
      `  ${(png.length / 1024).toFixed(0)} KB   ${why}`,
  );
  if (!ok) process.exitCode = 1;
}
console.log(`\n  ${JOBS.length} file(s), ${(bytes / 1024 / 1024).toFixed(2)} MB, in ${OUT}/`);
