import { playerSpriteName, spriteNameFromPaletteColor, PLAYER_COLORS } from "../constants.js";

console.log("=== playerSpriteName (by colorIndex) ===");
for (let i = 0; i < 12; i++) {
  console.log(`  player ${i}: ${playerSpriteName(i)} (palette=${PLAYER_COLORS[i % PLAYER_COLORS.length]})`);
}

console.log("\n=== spriteNameFromPaletteColor ===");
for (const c of [3, 14, 8, 10, 7, 9, 11, 12]) {
  console.log(`  palette ${c}: ${spriteNameFromPaletteColor(c)}`);
}

console.log("\n=== Unknown palette color ===");
console.log(`  palette 4: ${spriteNameFromPaletteColor(4)}`);
