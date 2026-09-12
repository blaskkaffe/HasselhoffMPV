/* Wind-Up Fairway
   src/game.h

   Top-level game state machine: aiming, charging the pull-back power,
   watching the car roll, and sinking the shot. Has no KOS dependency
   (input_t is a plain struct, hud_info_t is filled in for render.c). */

#ifndef GAME_H
#define GAME_H

#include "physics.h"
#include "course.h"
#include "car.h"
#include "input.h"
#include "render.h"

typedef enum {
    GS_AIM = 0,
    GS_CHARGE,
    GS_ROLLING,
    GS_SUNK,
} game_state_t;

typedef struct {
    car_body_t     car;
    const course_t *course;
    int             car_index;
    const car_stats_t *stats;

    game_state_t state;
    float aim_angle;
    float charge_elapsed;
    float locked_curve;
    float sunk_timer;

    int strokes;
} game_t;

void game_init(game_t *g, const course_t *course);
void game_update(game_t *g, const input_state_t *in, float dt_sec, hud_info_t *out_hud);

#endif /* GAME_H */
