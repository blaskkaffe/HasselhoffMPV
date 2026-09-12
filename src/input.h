/* Wind-Up Fairway
   src/input.h

   Thin wrapper around the first Maple controller. Converts raw analog
   ranges into normalized floats and tracks button edges so game.c doesn't
   need to know about maple/cont_state_t directly. */

#ifndef INPUT_H
#define INPUT_H

typedef struct {
    int   connected;

    float aim_axis;     /* -1..1, left stick X (also fed by D-pad) */
    float curve_axis;   /* -1..1, right trigger minus left trigger */

    int   action_down;      /* A held */
    int   action_pressed;   /* A pressed this frame */
    int   action_released;  /* A released this frame */

    int   start_pressed;    /* Start pressed this frame */
    int   cycle_pressed;    /* X pressed this frame (cycles car at the tee) */
} input_state_t;

void input_poll(input_state_t *out);

#endif /* INPUT_H */
