//go:build ignore

// extract_sprites bakes palette-indexed 12×12 sprite templates out of the
// game's spritesheet.png using the game's palette (pallete.png, yes that's
// the filename). It writes one .bin per tile into testdata/; each byte is
// either a palette index 0..15 or 255 (transparent, alpha < 20 — matching
// common/server.nim:nearestPaletteIndex).
//
// Run from the lively_lecun directory:
//
//	go run cmd/extract_sprites/main.go
//
// Paths assume the repo layout at among_them/players/lively_lecun/.
package main

import (
	"fmt"
	"image"
	"image/color"
	_ "image/png"
	"log"
	"os"
	"path/filepath"
)

const (
	paletteRelPath = "../../../clients/data/pallete.png"
	// spritesheet.png in the repo is stale -- tile 7 (ghost icon) was
	// only added to spritesheet.aseprite. Re-render first with:
	//
	//   cd /Users/sasmith/code/bitworld2
	//   nim c --path:common --path:. -r render_sheet.nim
	//
	// and point this at the fresh render. The rendered PNG lives at
	// /tmp/spritesheet_full.png by default; the committed copy lives in
	// testdata/ so extraction is reproducible without Nim.
	sheetRelPath   = "testdata/spritesheet_full.png"
	testdataDir    = "testdata"
	spriteSize     = 12
	transparentIdx = 255
	alphaCutoff    = 20
)

var extracts = []struct {
	tile int    // column index into the sheet (sheet.subImage(tile*SpriteSize, 0, ...))
	name string // output filename under testdataDir
}{
	{0, "player_sprite.bin"},
	{1, "body_sprite.bin"},
	{3, "kill_icon.bin"},
	{7, "ghost_icon.bin"},
}

func loadImage(path string) image.Image {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("open %s: %v", path, err)
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		log.Fatalf("decode %s: %v", path, err)
	}
	return img
}

func loadPalette(path string) [16]color.RGBA {
	img := loadImage(path)
	b := img.Bounds()
	if b.Dx() < 16 || b.Dy() < 1 {
		log.Fatalf("palette too small: %dx%d", b.Dx(), b.Dy())
	}
	var pal [16]color.RGBA
	for i := 0; i < 16; i++ {
		r, g, bl, a := img.At(b.Min.X+i, b.Min.Y).RGBA()
		pal[i] = color.RGBA{uint8(r >> 8), uint8(g >> 8), uint8(bl >> 8), uint8(a >> 8)}
	}
	return pal
}

// nearestIndex mirrors common/server.nim:nearestPaletteIndex: low-alpha
// pixels are transparent; otherwise pick the palette entry minimizing
// (dr² + dg² + db² + da²).
func nearestIndex(pal [16]color.RGBA, c color.RGBA) uint8 {
	if c.A < alphaCutoff {
		return transparentIdx
	}
	best := 0
	bestD := int(^uint(0) >> 1)
	for i, p := range pal {
		dr := int(c.R) - int(p.R)
		dg := int(c.G) - int(p.G)
		db := int(c.B) - int(p.B)
		da := int(c.A) - int(p.A)
		d := dr*dr + dg*dg + db*db + da*da
		if d < bestD {
			bestD = d
			best = i
		}
	}
	return uint8(best)
}

func extractTile(img image.Image, pal [16]color.RGBA, tile int) []byte {
	b := img.Bounds()
	out := make([]byte, spriteSize*spriteSize)
	for y := 0; y < spriteSize; y++ {
		for x := 0; x < spriteSize; x++ {
			sx := b.Min.X + tile*spriteSize + x
			sy := b.Min.Y + y
			r, g, bl, a := img.At(sx, sy).RGBA()
			out[y*spriteSize+x] = nearestIndex(pal, color.RGBA{
				uint8(r >> 8), uint8(g >> 8), uint8(bl >> 8), uint8(a >> 8),
			})
		}
	}
	return out
}

func main() {
	log.SetFlags(0)
	pal := loadPalette(paletteRelPath)
	sheet := loadImage(sheetRelPath)
	if err := os.MkdirAll(testdataDir, 0o755); err != nil {
		log.Fatalf("mkdir: %v", err)
	}
	for _, e := range extracts {
		bytes := extractTile(sheet, pal, e.tile)
		out := filepath.Join(testdataDir, e.name)
		if err := os.WriteFile(out, bytes, 0o644); err != nil {
			log.Fatalf("write %s: %v", out, err)
		}
		var opaque int
		for _, v := range bytes {
			if v != transparentIdx {
				opaque++
			}
		}
		fmt.Printf("wrote %s: tile %d, %d opaque of %d\n", out, e.tile, opaque, len(bytes))
	}
}
