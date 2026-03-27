---
name: terrain_preferences
description: User wants smoother average terrain with vast hills, valleys and plains in open world. Trees should appear in deliberate clumps.
type: feedback
---

Open world terrain should have smooth rolling landscape with vast-scale features — big hills, valleys, and open plains. Trees should be placed in deliberate clumps rather than uniform noise distribution.

**Why:** User explicitly requested "smoother average terrain but add vast hills, valleys and plains" and "trees should appear in more deliberate clumps" (2026-03-25).

**How to apply:** When modifying open world terrain generation, use large-wavelength noise for major features and minimize fine-frequency bumps. Tree placement should use a clump/cluster algorithm rather than per-cell random probability.
