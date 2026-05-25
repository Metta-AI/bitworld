# Party Progressor Asset Pipeline

Date: 2026-05-25
Status: Active

## Source Of Truth

Party Progressor now treats project-local imagegen assets as the preferred
monster art path. TribalCog art remains useful inspiration and runtime fallback,
but newly added Party Progressor monsters should live under:

- `data/generated/monsters/*.png`: checked-in runtime 32x32 sprites.
- `data/prompts/monster_assets.tsv`: prompt rows compatible with the older
  TribalCog TSV generator when imagegen is unavailable.
- `scripts/prepare_monster_assets.py`: crops transparent imagegen outputs into
  the 32x32 runtime cell.

The current imagegen pass added sprites for:

- `pack_alpha`
- `thorn_mender`
- `banner_goblin`
- `net_thrower`
- `bog_witch`
- `leech_swarm`
- `fire_scorpion`
- `sand_burrower`
- `ice_shaman`
- `snow_stalker`
- `crystal_seer`
- `ruin_necromancer`

## Preferred Workflow

1. Generate one monster at a time with the Codex imagegen skill.
2. Use a flat chroma-key background in the prompt (`#ff00ff`, or `#00ff00`
   when magenta-like subject colors are important).
3. Remove the chroma key with the shared helper:

   ```sh
   python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/scripts/remove_chroma_key.py" \
     --input data/generated/monsters/<monster>_source.png \
     --out data/generated/monsters/<monster>_full.png \
     --auto-key border \
     --soft-matte \
     --transparent-threshold 12 \
     --opaque-threshold 220 \
     --despill
   ```

4. Prepare the runtime sprite:

   ```sh
   python3 scripts/prepare_monster_assets.py
   ```

5. Keep the final `data/generated/monsters/<monster>.png` in the repo. Large
   source images can stay in the local imagegen output directory unless a pass
   specifically needs checked-in source art.

## TribalCog Fallback

`data/prompts/monster_assets.tsv` intentionally keeps the older TribalCog
two-or-three-column TSV format:

```text
output.png<TAB>prompt<TAB>source=imagegen
```

If imagegen is unavailable, the rows can be copied into the old TribalCog
`scripts/generate_assets.py --postprocess` flow or adapted to the newer games
ArtGen folder tree. That fallback should still promote final assets back into
Party Progressor's `data/generated/monsters/` namespace rather than depending
on a shared TribalCog folder at runtime.
