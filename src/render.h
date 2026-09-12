/* Wind-Up Fairway
   src/render.h

   All GLdc (OpenGL-for-Dreamcast) rendering: 3D scene (ground, walls, hole,
   car) plus a thin call-out to the 2D HUD overlay in hud.c. */

#ifndef RENDER_H
#define RENDER_H

#include "physics.h"
#include "course.h"

typedef struct {
    int   show_aim_arrow;    /* draw the ground arrow from the car */
    int   show_power_meter;  /* draw the charge bar */
    float charge01;
    float curve01;
    int   strokes;
    int   par;
    int   show_sunk_banner;
} hud_info_t;

void render_init(void);
void render_frame(const car_body_t *car, const course_t *course, const hud_info_t *hud);

#endif /* RENDER_H */
