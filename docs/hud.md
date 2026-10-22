# The HUD and the menus

The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## The HUD is dot-ui's glance pieces

The clock is a `DotScoreStrip` with the props and hunters still up as its two side plates in the sides' colours, and "Hunters released in · <map>" under it (the blindfold's own clock uses `DotScoreStrip.clock_text` too, so the two never disagree by a second). "Look at a prop and become it" is a `DotKeyPrompt` under the crosshair with the disguise key as bound. **Health is a `DotVitals`, not the old number on a disc**: a prop's health is a share of a size-derived maximum (10 to 200), so a bare number said nothing about how much of you is left; the bar says the share, its fill keeps the side's colour the disc carried, and the cross is drawn only on a body. The plate ends 214 pixels off the bottom, above the chat box's full eight-row log (202). Colours are the menu theme's, set on the HUD's root by dot-menu's `follow_hud` with `PhHud.piece_theme()` (the map blue) as the accent, so a theme picked in the menu restyles the whole HUD live and the default is dark (Christian's first play test). **A hunter's ammunition is a `DotAmmoCounter` bottom right**, counting the drawn gun (`PhHud.weapons_fn`), which `PhClient.correct_drawn` brings to the server's count once quiet 0.6 s. `headless_run` checks the pieces, the plate against the chat log, the counter and the offline correction (armed); `headless_net` checks the online one, a real `PhClient` reading the owner-only `net_magazine`/`net_reserve` through the bridge (armed), and that the derived `requires.json` asks for dot-ui 4.

**H is help** (dot-menu's stock key and its top-right "H Help" plate; `PhSettings._fill_help` writes the goal and each side's rules), so nothing in `PhBindings` may default to H, and the Escape menu has dot-menu's stock Help and Leave. `headless_run` checks both.

**M is the map list** (dot-menu's map menu): `PhGame.map_rows()` and `change_map_now()` (the next map plus dot-match's `begin_round_now`) serve both solo and the server, where dot-vote's map menu lets the owner's `sv_map_menu_flag` change it now and gives anybody else a vote. It shares the taunt list's picker; a map choice never reaches `_on_taunt_picked`. Nothing in `PhBindings` may default to M; `headless_run` and `dedicated` check it.

## Sound

Sound follows the map document: each box's `mat` is its collision shape's `surface` meta, so footsteps go by surface (dot-audio's `DotAudioFootsteps`); every `ceiling` or `roof` box is an indoor ambience zone; the outdoor bed and ground come from `PhAudio.MAP_SOUND` or the document's `ambience` and `surface`. Levels are measured with `addons/dot_audio/tools/loudness.sh` and held in the family's −17 LUFS band by `loudness_trim_db`. A dead person's landing is dot-player-char's stock death sounds, in `PhAudio`'s catalogue.

## A hit

A hit is the server's word: `PhGame.hit_landed` from each weapon shot's damages on a player, sent as HIT to the shooter alone, drawn as dot-ui's `DotHitMarker` and zee's red burst on the body (`ZeeShotFx.play_body_hit`, called by `has_method` so an older pack still runs). It tells a hunter that a disguised prop was hit, which the health the hunter does not lose already says, so it gives nothing away. `headless_run` checks the marker; `headless_net` checks the wire: a hunter's shot into the stand-in is HIT to that hunter's peer, none to a second ready peer and none broadcast, and a hit the hunter takes is no marker (armed: it fails with the bridge's send removed, or broadcast).


A spectator's line names G (free camera) only while the server offers one (`mp_freeroam`, and `mp_forcecamera` 0); `PhSpectate.line_for` takes the key's name. While flying, the line lists the controls instead of a name. The request is the fourth value of the SPECTATE ask's two bits, the view that comes back is ROAMING with no target, and the client flies the camera per frame at `mp_freeroam_speed`.
