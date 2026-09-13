# Rendering and device validation

The default Balanced preset targets 60 fps on iPhone 13 Pro. This is a target, not a measured device guarantee.

## Rendering budget

- Balanced starts at 80% native resolution with 2x MSAA. UIKit controls stay at native resolution.
- Resolution adapts in small steps between 60% and the selected preset's ceiling after sustained slow frames or serious/critical thermal state. Recovery is deliberately slower.
- The directional shadow uses a 2048 map, two cascades and a 110 m maximum distance. Balanced avoids tree shadow draws, depth of field and motion blur.
- Nearby trees retain individual identities for collision and destruction. Crowns and trunks have lower-detail meshes from 160/180 m; beyond 300 m sector centres, simplified forest geometry is batched to one draw per 120 m sector.
- Sector visibility is updated at 5 Hz. Hidden sectors skip their complete subtree. Fog conceals the outer cutoff.
- Open-world terrain is split into 100 tiles with tight bounds. Balanced retains the original 240-by-240 total grid resolution.
- Opaque foliage avoids alpha-card overdraw. Static bike parts share a small material palette and are flattened. Exhaust remains separately animated.
- Physics uses bounded steps of at most 1/120 s. Swept tree tests cover the travelled segment. HUD/haptic updates run at up to 30 Hz.
- Procedural textures are small RGBA8 images; a generated panorama supplies material reflections. No downloaded models or texture packs are required.

## Reproducible simulator checks

Debug builds accept launch arguments:

- `--preview-race`: open the race directly.
- `--preview-world`: open the island directly.
- `--autopilot`: apply throttle and basic steering for repeatable driving checks.
- `--diagnostics`: log race state, speed, position, visible sector count, averaged frame interval and resolution scale every three seconds.

These switches are excluded from Release. The autopilot is a test aid, not a player feature.

## iPhone 13 Pro acceptance pass still required

Use a signed Release build on the physical phone with Balanced selected. Disable Low Power Mode for the baseline, and record both cold-start and warmed-up behaviour.

1. Drive the full race, retry after a collision, finish a race, and verify best times.
2. Spend at least 15 minutes in open world, including sustained boost, forest boundaries, hill crests and shoreline turns.
3. Record frame-time distribution with Instruments Game Performance / Metal System Trace. Aim for a 16.7 ms frame budget and inspect long-frame spikes separately from average FPS.
4. Record peak memory and thermal state; watch resolution recovery when the load drops. Resolution cannot correct CPU bottlenecks, so inspect sector traversal and physics separately if the scale reaches its floor.
5. Check tilt steering, lift, multi-touch brake/boost, haptics, both landscape orientations, app switching and audio interruptions on hardware.

## Local toolchain limitation

The installed Xcode 26.5 SDK has no matching simulator runtime. A normal Xcode asset-catalog build currently fails before compilation. Direct Swift compilation/linking and an installed simulator preview provide code and visual checks, but do not replace a signed-device build or A15 profiling.
