/* Wind-Up Fairway
   src/main.c

   Entry point: bring up GLdc, wire input -> game -> render together, and
   run the frame loop. A+B+X+Y+Start still resets to the BIOS menu via
   KOS's default handler, so there's no explicit quit path here. */

#include <kos.h>

#include "input.h"
#include "game.h"
#include "render.h"
#include "course.h"

int main(int argc, char *argv[]) {
    render_init();

    game_t game;
    game_init(&game, &course_hole1);

    uint64_t last_ms = timer_ms_gettime64();

    for(;;) {
        uint64_t now_ms = timer_ms_gettime64();
        float dt_sec = (float)(now_ms - last_ms) / 1000.0f;
        last_ms = now_ms;

        /* Clamp dt so a hitch (or the very first frame) can't launch the
           car through a wall or skip the charge bar. */
        if(dt_sec > 0.1f) dt_sec = 0.1f;

        input_state_t input;
        input_poll(&input);

        hud_info_t hud;
        game_update(&game, &input, dt_sec, &hud);

        render_frame(&game.car, game.course, &hud);
    }

    return 0;
}
