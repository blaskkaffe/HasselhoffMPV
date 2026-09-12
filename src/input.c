#include "input.h"

#include <kos.h>

void input_poll(input_state_t *out) {
    static int prev_action_down = 0;
    static int prev_x_down = 0;

    maple_device_t *dev = maple_enum_type(0, MAPLE_FUNC_CONTROLLER);

    if(!dev) {
        out->connected = 0;
        out->aim_axis = 0.0f;
        out->curve_axis = 0.0f;
        out->action_down = 0;
        out->action_pressed = 0;
        out->action_released = 0;
        out->start_pressed = 0;
        out->cycle_pressed = 0;
        prev_action_down = 0;
        prev_x_down = 0;
        return;
    }

    cont_state_t *st = (cont_state_t *)maple_dev_status(dev);

    if(!st) {
        out->connected = 0;
        return;
    }

    out->connected = 1;

    float axis = (float)st->joyx / 127.0f;
    if(st->dpad_left)  axis = -1.0f;
    if(st->dpad_right) axis = 1.0f;
    if(axis < -1.0f) axis = -1.0f;
    if(axis > 1.0f) axis = 1.0f;
    out->aim_axis = axis;

    out->curve_axis = ((float)st->rtrig - (float)st->ltrig) / 255.0f;

    out->action_down = st->a ? 1 : 0;
    out->action_pressed = (out->action_down && !prev_action_down) ? 1 : 0;
    out->action_released = (!out->action_down && prev_action_down) ? 1 : 0;
    prev_action_down = out->action_down;

    out->start_pressed = st->start ? 1 : 0;

    int x_down = st->x ? 1 : 0;
    out->cycle_pressed = (x_down && !prev_x_down) ? 1 : 0;
    prev_x_down = x_down;
}
