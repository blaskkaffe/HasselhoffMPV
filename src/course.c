#include "course.h"

/* Hole 1: a straight fairway with a single dogleg wall jutting in from the
   left, forcing either a curved shot around it or a bank off the right
   wall. Boundary is a simple rectangle; the fifth wall is the obstacle. */

static const wall_t hole1_walls[] = {
    { -15.0f,  0.0f,  -15.0f, 50.0f },  /* left boundary  */
    {  15.0f,  0.0f,   15.0f, 50.0f },  /* right boundary */
    { -15.0f,  0.0f,   15.0f,  0.0f },  /* near boundary  */
    { -15.0f, 50.0f,   15.0f, 50.0f },  /* far boundary   */
    { -15.0f, 22.0f,    3.0f, 22.0f },  /* dogleg obstacle */
};

const course_t course_hole1 = {
    .name          = "Hole 1: The Dogleg",
    .par           = 3,

    .start_x       = 0.0f,
    .start_z       = 4.0f,
    .start_heading = 0.0f,

    .hole_x        = 6.0f,
    .hole_z        = 45.0f,
    .hole_radius   = 1.0f,

    .half_width    = 15.0f,
    .length        = 50.0f,

    .walls         = hole1_walls,
    .wall_count    = sizeof(hole1_walls) / sizeof(hole1_walls[0]),
};
