#include "game.h"

#define CHARGE_MAX_SEC  1.4f
#define MIN_CHARGE      0.12f
#define AIM_TURN_RATE   2.2f   /* rad/sec at full stick deflection */
#define SUNK_HOLD_SEC   3.0f   /* auto-restart if Start isn't pressed */

static float clamp01(float v) {
    if(v < 0.0f) return 0.0f;
    if(v > 1.0f) return 1.0f;
    return v;
}

static void start_hole(game_t *g) {
    g->strokes = 0;
    g->aim_angle = g->course->start_heading;
    g->charge_elapsed = 0.0f;
    g->locked_curve = 0.0f;
    g->sunk_timer = 0.0f;
    g->state = GS_AIM;
    physics_reset(&g->car, g->course);
}

void game_init(game_t *g, const course_t *course) {
    g->course = course;
    g->car_index = 0;
    g->stats = &car_presets[0];
    start_hole(g);
}

void game_update(game_t *g, const input_state_t *in, float dt_sec, hud_info_t *out_hud) {
    float charge01 = 0.0f;

    switch(g->state) {
        case GS_AIM:
            g->aim_angle += in->aim_axis * AIM_TURN_RATE * dt_sec;
            g->car.heading = g->aim_angle;

            if(g->strokes == 0 && in->cycle_pressed) {
                g->car_index = (g->car_index + 1) % CAR_COUNT;
                g->stats = &car_presets[g->car_index];
            }

            if(in->action_pressed) {
                g->charge_elapsed = 0.0f;
                g->locked_curve = in->curve_axis;
                g->state = GS_CHARGE;
            }
            break;

        case GS_CHARGE:
            g->charge_elapsed += dt_sec;
            charge01 = clamp01(g->charge_elapsed / CHARGE_MAX_SEC);

            if(in->action_released) {
                if(charge01 >= MIN_CHARGE) {
                    physics_launch(&g->car, g->aim_angle, charge01,
                                   g->locked_curve, g->stats);
                    g->strokes++;
                    g->state = GS_ROLLING;
                } else {
                    g->state = GS_AIM;
                }
            }
            break;

        case GS_ROLLING: {
            phys_event_t ev = physics_update(&g->car, g->stats, g->course, dt_sec);

            if(ev == PHYS_EVENT_SUNK) {
                g->sunk_timer = 0.0f;
                g->state = GS_SUNK;
            } else if(ev == PHYS_EVENT_STOPPED) {
                g->aim_angle = g->car.heading;
                g->state = GS_AIM;
            }
            break;
        }

        case GS_SUNK:
            g->sunk_timer += dt_sec;
            if(in->start_pressed || g->sunk_timer > SUNK_HOLD_SEC)
                start_hole(g);
            break;
    }

    out_hud->show_aim_arrow = (g->state == GS_AIM || g->state == GS_CHARGE);
    out_hud->show_power_meter = (g->state == GS_CHARGE);
    out_hud->charge01 = charge01;
    out_hud->curve01 = g->locked_curve;
    out_hud->strokes = g->strokes;
    out_hud->par = g->course->par;
    out_hud->show_sunk_banner = (g->state == GS_SUNK);
}
