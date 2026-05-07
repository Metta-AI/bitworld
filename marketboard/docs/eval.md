# Evaluation & Testing Guidelines

## Core Principle

If bots need 100k ticks to reach T3, the bots are broken — not the test. Extending tick counts masks bad behavior. A well-functioning economy with smart bots should reach full T3 gear in **under 10k ticks** with a balanced lineup.

## What Was Wrong

Previous testing ran 50 matches × 100k ticks each. This:
- Wasted hours of CPU time
- Gave identical outcomes (bots get stuck in the same loops)
- Hid the real problem (bots are dumb, not underlucky)
- Made iteration impossible (can't test a hypothesis if each run takes 10 minutes)

## Testing Rules

### Quick Iteration (during development)
```
./tools/batch_market --matches:1 --ticks:10000 --fixed-lineup
```
- **1 match, 10k ticks, fixed lineup**
- Should complete in under 5 seconds
- If no bot reaches T2 by 5k ticks, something is wrong
- If no bot reaches T3 by 10k ticks, the bots need fixing (not more ticks)

### Diagnosis (when something looks off)
```
./tools/diagnose_bots --seed:0 --ticks:10000 --interval:2500 --fixed-lineup > tmp/diag.txt
```
- Run once, write to `tmp/` (gitignored), read the file to analyze
- Do NOT re-run multiple times — read the output you already have
- No `--filter` — capture all bots in one run, grep the file for specific bots
- Look for: excessive phase cycling, long stretches without gear upgrades, hoarding without selling

### Validation (before committing)
```
./tools/batch_market --matches:1 --ticks:10000 --fixed-lineup
```
- 1 match, 10k ticks
- Should finish in a few seconds
- Success criteria: at least one bot at T3

### Never Do
- `--ticks:100000` — if you need this, fix the bots
- `--matches:50` — diminishing returns, 1 match is enough
- Running diagnose/batch_market multiple times — run once, write to `tmp/`, read the file
- Using `--filter` when you can just grep the output file

## Success Targets

| Milestone | Target Ticks | What It Means |
|-----------|-------------|---------------|
| First T1 gear equipped | < 500 | Crafters are producing, market works |
| Full T1 on any bot | < 2000 | Economy is flowing |
| First T2 gear equipped | < 3000 | Tier progression works |
| Full T2 on any bot | < 6000 | Supply chain scales |
| First T3 gear equipped | < 8000 | High-tier economy works |
| Full T3 on any bot | < 10000 | Bots are smart enough |

These are aspirational but reasonable. A human player in this sim would plan ahead, batch trips, and reach T3 far faster than current bots. The gap between bot and human performance is the problem to solve.

## What to Look For in Diagnostics

**Healthy signs:**
- Bots gather 3-5 items before selling
- Gear purchases happen within 100 ticks of gear appearing on market
- Crafters buy materials in batches matching recipe requirements
- Role distribution adapts to market needs

**Sick signs:**
- Gather → sell → gather → sell with 1 item each time (batching failure)
- All bots PathToBuyStall on the same tick (hive mind)
- Bot has 500g but no gear upgrades (not checking market / nothing available)
- Crafter idle with gold but no materials on market (supply chain broken)
- Gatherers all at the same node (spatial spread failure)
