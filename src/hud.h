/* Wind-Up Fairway
   src/hud.h

   2D screen-space HUD: a charge/power meter and an LED-style (7-segment)
   number renderer used for the stroke counter and par. Deliberately avoids
   any font/texture API so there is nothing to load or fail to load. */

#ifndef HUD_H
#define HUD_H

/* Switches GL into a 640x480 orthographic overlay. Call once per frame
   after the 3D scene has been drawn, before any hud_draw_* call. */
void hud_begin_overlay(void);

/* Restores the perspective/modelview matrices used for the 3D scene. */
void hud_end_overlay(void);

/* Draws the pull-back charge bar. curve01 is -1..1 and shows up as a
   marker offset within the bar; charge01 is 0..1 fill amount. */
void hud_draw_power_meter(float charge01, float curve01);

/* Draws a non-negative integer at (x, y) (bottom-left origin) using
   digit_w x digit_h LED-style digits. */
void hud_draw_number(float x, float y, float digit_w, float digit_h, int value);

#endif /* HUD_H */
