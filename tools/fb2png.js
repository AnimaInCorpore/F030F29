// Convert a raw Falcon truecolour framebuffer dump to a PPM (pipe through
// ImageMagick for PNG).  Matches the 320x240 16bpp RGB565 work/display buffers.
//
//   node tools/fb2png.js frame.bin frame.ppm [width] [height]

const fs = require("fs");

if(process.argv.length < 4) {
    console.log("usage: node tools/fb2png.js <in.bin> <out.ppm> [width] [height]");
    process.exit(1);
}

const width = parseInt(process.argv[4] || "320", 10);
const height = parseInt(process.argv[5] || "240", 10);

const raw = fs.readFileSync(process.argv[2]);
const header = Buffer.from("P6\n" + width + " " + height + "\n255\n", "ascii");
const pixels = Buffer.alloc(width * height * 3);

let out = 0;

for(let y = 0; y < height; y++) {
    for(let x = 0; x < width; x++) {
        const word = raw.readUInt16BE((y * width + x) * 2);

        // RGB565, scaled so 31/63 map to 255 rather than 248/252.
        pixels[out++] = Math.round((((word >> 11) & 31) * 255) / 31);
        pixels[out++] = Math.round((((word >> 5) & 63) * 255) / 63);
        pixels[out++] = Math.round(((word & 31) * 255) / 31);
    }
}

fs.writeFileSync(process.argv[3], Buffer.concat([header, pixels]));
